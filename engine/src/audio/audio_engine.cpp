// Live audio engine: miniaudio duplex device, playback track with pitch shift,
// capture ring buffer, MPM + SwiftF0 pitch tracking, latency calibration.
// Implements the ke_audio_* functions of karaoke_engine.h.
//
// Threads
// -------
//   device callback  : miniaudio real-time thread. Allocation-free and lock-free:
//                      reads atomics, renders the track (optionally through the
//                      signalsmith stretcher using preallocated buffers), writes
//                      captured audio into an ma_pcm_rb (SPSC) and a small
//                      lock-free ring of "sync records" (capture index <-> track
//                      frame) so workers can map capture time to the playback clock.
//   dsp worker       : drains the ring: growable capture buffer (for save), MPM
//                      pitch every 10 ms on 2048-sample windows (source=0),
//                      streaming resample to 16 kHz for the model worker.
//   model worker     : SwiftF0 on a sliding ~1 s window every 160 ms (10 frames),
//                      emitting frames that have >= 10 frames of lookahead
//                      (swift-f0 PitchStream semantics), source=1.
//   API threads      : every ke_audio_* call; start/stop/load/calibrate are
//                      serialised with api_mutex (never taken by the callback).
//
// Clock
// -----
//   The playback clock is the number of track frames the callback has rendered.
//   With the pitch shifter engaged the stretcher adds L = inputLatency+outputLatency
//   samples of delay; the cursor is advanced by L when the shifter is switched on
//   (and rewound when it is switched off) so ke_audio_position() always reports the
//   frame that is audible at the device output ("audible frame").
//   Capture sample c is stamped on the playback clock through the sync record of the
//   callback block that delivered it, minus the latency compensation.
#include "karaoke_engine.h"
#include "dsp/hall_reverb.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "miniaudio/miniaudio.h"
#include "nlohmann/json.hpp"
#include "signalsmith-stretch/signalsmith-stretch.h"

#include "core/error.h"
#include "core/resample.h"
#include "core/wav.h"
#include "dsp/mpm.h"
#include "models/swiftf0.h"

namespace {

using json = nlohmann::json;
using Clock = std::chrono::steady_clock;

constexpr int kMaxBlock = 16384;          // frames per callback we are prepared for (chunked above)
constexpr double kRingSeconds = 8.0;      // capture ring capacity
constexpr size_t kSyncCap = 8192;         // sync records (power of two)
constexpr int kMpmWindow = 2048;
constexpr double kMpmHopSeconds = 0.010;
constexpr int kModelLeftFrames = 11;      // swift-f0 LEFT_FRAMES
constexpr int kModelLookahead = 10;       // swift-f0 LOOKAHEAD_FRAMES
constexpr int kModelWindowFrames = 62;    // ~1 s at 16 ms
constexpr int kModelEmitFrames = 10;      // run every 160 ms
constexpr double kCalibSeconds = 1.5;
constexpr int kCalibClicks = 5;
constexpr double kCalibClickSpacing = 0.2;
constexpr double kCalibFirstClick = 0.2;
constexpr double kCalibMaxLag = 0.45;
constexpr double kPi = 3.14159265358979323846;

struct SyncRec {
    int64_t capture_index;   // capture sample index of the block start (since capture start)
    int64_t track_frame;     // audible track frame at the block start
    int32_t playing;
};

struct Track {
    std::vector<float> left, right;
    int64_t frames = 0;
    int sample_rate = 0;
};

// Metronome clicks in track frames (sorted), with an accent flag per click.
struct Clicks {
    std::vector<int64_t> frames;
    std::vector<uint8_t> accent;
};

std::string ma_err(ma_result r) { return ma_result_description(r); }

// Device ids are backend specific unions; serialise them losslessly as hex so Dart
// can hand them back unchanged on any platform.
std::string encode_device_id(const ma_device_id& id) {
    const auto* b = reinterpret_cast<const unsigned char*>(&id);
    size_t n = sizeof(id);
    while (n > 0 && b[n - 1] == 0) --n;
    std::string s = "hex:";
    char tmp[4];
    for (size_t i = 0; i < n; ++i) { std::snprintf(tmp, sizeof(tmp), "%02x", b[i]); s += tmp; }
    return s;
}

bool decode_device_id(const std::string& s, ma_device_id& id) {
    std::memset(&id, 0, sizeof(id));
    if (s.rfind("hex:", 0) == 0) {
        const std::string h = s.substr(4);
        if (h.size() % 2 || h.size() / 2 > sizeof(id)) return false;
        auto* b = reinterpret_cast<unsigned char*>(&id);
        for (size_t i = 0; i < h.size() / 2; ++i) {
            unsigned v = 0;
            if (std::sscanf(h.c_str() + 2 * i, "%2x", &v) != 1) return false;
            b[i] = static_cast<unsigned char>(v);
        }
        return true;
    }
    // Plain string: works for the char[256] backends (CoreAudio UID, ALSA, PulseAudio).
    if (s.size() >= sizeof(id)) return false;
    std::memcpy(&id, s.data(), s.size());
    return true;
}

float db_of_rms(double rms) { return static_cast<float>(20.0 * std::log10(std::max(rms, 1e-7))); }

}  // namespace

struct ke_audio {
    // ---- configuration / device --------------------------------------------------
    int sr = 48000;
    ma_context ctx{};
    bool ctx_ok = false;
    ma_device dev{};
    bool dev_ok = false;
    double in_latency = 0.0, out_latency = 0.0;
    std::mutex api_mutex;

    // ---- callback bookkeeping ----------------------------------------------------
    std::atomic<uint64_t> cb_count{0};
    std::atomic<int64_t> cb_ns{0};               // steady_clock ns at the last callback
    std::atomic<uint32_t> cb_frames{0};

    // ---- track -------------------------------------------------------------------
    std::atomic<Track*> track{nullptr};
    std::atomic<bool> playing{false};
    std::atomic<int64_t> seek_request{-1};
    std::atomic<float> volume{1.f};
    std::atomic<float> pitch_semitones{0.f};
    std::atomic<int64_t> audible_frame{0};        // playback clock (frame at device output)
    std::atomic<Clicks*> clicks{nullptr};         // metronome (owned; swapped by the API)
    std::atomic<float> click_gain{0.f};           // 0 = metronome off
    // ---- vocal return (mic -> output) + hall reverb ------------------------------
    std::atomic<bool> vocal_return{false};
    std::atomic<bool> reverb_on{false};
    std::atomic<float> reverb_mix{0.25f};
    std::unique_ptr<ke::HallReverb> reverb;       // null when the rate is above 48 kHz
    // callback-local
    float vr_gain = 0.f;                          // smoothed 0..1 (fades the return in/out)
    float vr_mix = 0.f;                           // smoothed wet mix actually applied
    int64_t reverb_flush = 0;                     // frames of silent input still to feed after the return stops
    std::vector<float> vr_dry, vr_wl, vr_wr;
    // ---- preview tone (sine, e.g. while dragging a note in the editor) ------------
    std::atomic<float> tone_hz{0.f};
    std::atomic<float> tone_gain{0.f};
    // callback-local
    double tone_phase = 0.0;
    float tone_freq = 0.f;                        // glides toward tone_hz
    float tone_env = 0.f;                         // fades toward tone_gain
    // callback-local state
    int64_t cursor = 0;                           // next track frame to feed
    float applied_gain = 1.f;
    bool stretch_active = false;
    float stretch_semitones = 0.f;
    signalsmith::stretch::SignalsmithStretch<float> stretch;
    int stretch_latency = 0;
    std::vector<float> st_in_l, st_in_r, st_out_l, st_out_r, preroll_l, preroll_r;

    // ---- capture -----------------------------------------------------------------
    ma_pcm_rb rb{};
    bool rb_ok = false;
    std::atomic<bool> capturing{false};
    std::atomic<int64_t> captured_total{0};
    std::atomic<uint32_t> ring_overflows{0};
    std::atomic<float> input_level_db{-100.f};
    float level_state = -100.f;                   // callback-local smoothing
    SyncRec sync_ring[kSyncCap];
    std::atomic<uint64_t> sync_head{0};           // producer (callback)
    uint64_t sync_tail = 0;                       // consumer (dsp worker)
    std::atomic<double> latency_comp{0.0};
    std::atomic<int> capture_mode{0};
    // worker statistics (logged at stop)
    std::atomic<int64_t> stat_detect_ns_max{0}, stat_detect_ns_total{0}, stat_detect_count{0};
    std::atomic<int64_t> stat_model_ns_max{0}, stat_model_ns_total{0}, stat_model_count{0};
    std::atomic<uint32_t> stat_backlog_max{0};

    // ---- calibration -------------------------------------------------------------
    std::atomic<int> calib_state{0};              // 0 idle, 1 running, 2 done
    std::vector<float> calib_out, calib_in;
    size_t calib_out_pos = 0, calib_in_pos = 0;

    // ---- workers -----------------------------------------------------------------
    std::atomic<bool> workers_run{false};
    std::thread dsp_thread, model_thread;
    std::mutex sync_mutex;                        // guards sync_list
    std::vector<SyncRec> sync_list;
    std::mutex capture_mutex;                     // guards capture_all, track_start_offset
    std::vector<float> capture_all;
    double track_start_offset = 0.0;
    bool track_synced = false;
    std::mutex frames_mutex;                      // guards f0_queue
    std::vector<float> f0_queue;                  // 5 floats per frame
    size_t f0_read = 0;
    // model path
    std::unique_ptr<ke::swiftf0::Model> model;
    std::mutex m16_mutex;
    std::condition_variable m16_cv;
    std::vector<float> pending16;
    ma_resampler resampler{};
    bool resampler_ok = false;

    // ------------------------------------------------------------------------------
    ~ke_audio() {
        // Workers must already be joined (ke_audio_destroy stops the capture first).
        playing.store(false);
        if (dev_ok) ma_device_uninit(&dev);        // joins the callback thread
        dev_ok = false;
        delete track.exchange(nullptr);
        delete clicks.exchange(nullptr);
        if (rb_ok) ma_pcm_rb_uninit(&rb);
        if (resampler_ok) ma_resampler_uninit(&resampler, nullptr);
        if (ctx_ok) ma_context_uninit(&ctx);
    }
    double map_time(int64_t c, bool* on_track);
    void push_frame(double t, float f0, float conf, float rms_db, float source);
    void data_callback(float* out, const float* in, ma_uint32 frames);
    void render_block(float* out, ma_uint32 frames);
    void mix_clicks(float* out, ma_uint32 frames, int64_t base);
    void mix_vocal_return(float* out, const float* in, ma_uint32 frames);
    void mix_tone(float* out, ma_uint32 frames);
    void set_stretch(bool enable);
    void dsp_worker();
    void model_worker();
    void wait_callback_cycles(int n);
    int swap_track(Track* t);
};

// ---------------------------------------------------------------------------------
// Device callback (real-time thread)
// ---------------------------------------------------------------------------------

static void ke_ma_callback(ma_device* dev, void* out, const void* in, ma_uint32 frames) {
    auto* a = static_cast<ke_audio*>(dev->pUserData);
    a->data_callback(static_cast<float*>(out), static_cast<const float*>(in), frames);
}

void ke_audio::set_stretch(bool enable) {
    // Called from the callback. Keeps the audible position continuous (see header comment).
    Track* t = track.load(std::memory_order_acquire);
    if (enable) {
        stretch.reset();
        const int L = stretch_latency;
        const int seek_len = stretch.seekLength();
        const int64_t end = cursor + L;                 // pre-roll ends where feeding resumes
        const int64_t begin = end - seek_len;
        for (int i = 0; i < seek_len; ++i) {
            const int64_t f = begin + i;
            const bool ok = t && f >= 0 && f < t->frames;
            preroll_l[i] = ok ? t->left[static_cast<size_t>(f)] : 0.f;
            preroll_r[i] = ok ? t->right[static_cast<size_t>(f)] : 0.f;
        }
        float* ins[2] = {preroll_l.data(), preroll_r.data()};
        stretch.seek(ins, seek_len, 1.0);
        cursor = end;
    } else {
        cursor = std::max<int64_t>(0, cursor - stretch_latency);
    }
    stretch_active = enable;
}

void ke_audio::render_block(float* out, ma_uint32 frames) {
    Track* t = track.load(std::memory_order_acquire);
    const int64_t seek = seek_request.exchange(-1, std::memory_order_acq_rel);
    if (seek >= 0) {
        cursor = t ? std::min<int64_t>(seek, t->frames) : 0;
        if (stretch_active) set_stretch(true);     // re-seek the stretcher's pre-roll
    }
    const bool play = playing.load(std::memory_order_acquire) && t;
    if (!play) {
        for (ma_uint32 i = 0; i < frames * 2; ++i) out[i] = 0.f;
        const int64_t audible = stretch_active ? std::max<int64_t>(0, cursor - stretch_latency) : cursor;
        audible_frame.store(t ? std::min<int64_t>(audible, t->frames) : 0, std::memory_order_release);
        return;
    }
    const float semis = pitch_semitones.load(std::memory_order_relaxed);
    const bool want = std::fabs(semis) > 1e-3f;
    if (want != stretch_active) set_stretch(want);
    if (want && semis != stretch_semitones) {
        stretch.setTransposeSemitones(semis);
        stretch_semitones = semis;
    }
    const float target_gain = volume.load(std::memory_order_relaxed);
    const float g0 = applied_gain;
    const float gstep = (target_gain - g0) / static_cast<float>(frames);

    if (!stretch_active) {
        const int64_t base = cursor;
        for (ma_uint32 i = 0; i < frames; ++i) {
            const float g = g0 + gstep * static_cast<float>(i);
            if (cursor < t->frames) {
                out[2 * i] = t->left[static_cast<size_t>(cursor)] * g;
                out[2 * i + 1] = t->right[static_cast<size_t>(cursor)] * g;
                ++cursor;
            } else {
                out[2 * i] = out[2 * i + 1] = 0.f;
            }
        }
        mix_clicks(out, frames, base);
        if (cursor >= t->frames) playing.store(false, std::memory_order_release);
        audible_frame.store(cursor, std::memory_order_release);
    } else {
        for (ma_uint32 i = 0; i < frames; ++i) {
            const int64_t f = cursor + i;
            const bool ok = f < t->frames;
            st_in_l[i] = ok ? t->left[static_cast<size_t>(f)] : 0.f;
            st_in_r[i] = ok ? t->right[static_cast<size_t>(f)] : 0.f;
        }
        float* ins[2] = {st_in_l.data(), st_in_r.data()};
        float* outs[2] = {st_out_l.data(), st_out_r.data()};
        stretch.process(ins, static_cast<int>(frames), outs, static_cast<int>(frames));
        for (ma_uint32 i = 0; i < frames; ++i) {
            const float g = g0 + gstep * static_cast<float>(i);
            out[2 * i] = st_out_l[i] * g;
            out[2 * i + 1] = st_out_r[i] * g;
        }
        // Output sample i plays track frame cursor + i - latency.
        mix_clicks(out, frames, cursor - stretch_latency);
        cursor += frames;
        const int64_t audible = std::max<int64_t>(0, cursor - stretch_latency);
        if (audible >= t->frames) playing.store(false, std::memory_order_release);
        audible_frame.store(std::min<int64_t>(audible, t->frames), std::memory_order_release);
    }
    applied_gain = target_gain;
}

// Vocal return: the microphone mixed into the output (dry, plus the hall
// reverb when on). The recording and pitch tracking always use the dry input
// captured above. Gains are ramped per block so toggling never clicks; after
// the return stops the reverb is fed silence for a few seconds so it starts
// clean next time.
void ke_audio::mix_vocal_return(float* out, const float* in, ma_uint32 frames) {
    const bool on = in && vocal_return.load(std::memory_order_relaxed);
    const float target_gain = on ? 1.f : 0.f;
    const float target_mix = reverb && reverb_on.load(std::memory_order_relaxed)
                                 ? std::clamp(reverb_mix.load(std::memory_order_relaxed), 0.f, 1.f)
                                 : 0.f;
    if (target_gain == 0.f && vr_gain == 0.f) {
        if (reverb && reverb_flush > 0) {
            for (ma_uint32 i = 0; i < frames; ++i) vr_dry[i] = 0.f;
            reverb->process_wet(vr_dry.data(), vr_wl.data(), vr_wr.data(), static_cast<int>(frames));
            reverb_flush -= frames;
        }
        vr_mix = target_mix;
        return;
    }
    const float g0 = vr_gain, m0 = vr_mix;
    const float gs = (target_gain - g0) / static_cast<float>(frames);
    const float ms = (target_mix - m0) / static_cast<float>(frames);
    // Clamped so a capture glitch cannot reach the headphones at full scale.
    for (ma_uint32 i = 0; i < frames; ++i) vr_dry[i] = in ? std::clamp(in[i], -1.f, 1.f) : 0.f;
    const bool use_reverb = reverb && (target_mix > 0.f || m0 > 0.f);
    if (reverb) {
        // Keep the reverb running while the return is on so switching it on is seamless.
        reverb->process_wet(vr_dry.data(), vr_wl.data(), vr_wr.data(), static_cast<int>(frames));
        reverb_flush = static_cast<int64_t>((ke::HallReverb::kDecaySeconds * 2.0) * sr);
    }
    for (ma_uint32 i = 0; i < frames; ++i) {
        const float g = g0 + gs * static_cast<float>(i);
        const float m = use_reverb ? m0 + ms * static_cast<float>(i) : 0.f;
        const float d = vr_dry[i] * ke::reverb_dry_gain(m) * g;
        const float wl = use_reverb ? vr_wl[i] * ke::reverb_wet_gain(m) * g : 0.f;
        const float wr = use_reverb ? vr_wr[i] * ke::reverb_wet_gain(m) * g : 0.f;
        out[2 * i] += d + wl;
        out[2 * i + 1] += d + wr;
    }
    vr_gain = target_gain;
    vr_mix = target_mix;
}

// Preview tone: a sine at tone_hz, faded in (~5 ms) and out (~30 ms) so
// starting and stopping never click, gliding (~10 ms) between pitches so a
// drag sounds continuous. Starting from silence it jumps straight to the pitch.
void ke_audio::mix_tone(float* out, ma_uint32 frames) {
    const float hz = tone_hz.load(std::memory_order_relaxed);
    const float target = hz > 0.f ? tone_gain.load(std::memory_order_relaxed) : 0.f;
    if (target == 0.f && tone_env < 1e-5f) {
        tone_env = 0.f;
        return;
    }
    if (hz > 0.f && (tone_env < 1e-5f || tone_freq <= 0.f)) tone_freq = hz;
    const float attack = 1.f - std::exp(-1.f / (0.005f * static_cast<float>(sr)));
    const float release = 1.f - std::exp(-1.f / (0.030f * static_cast<float>(sr)));
    const float glide = 1.f - std::exp(-1.f / (0.010f * static_cast<float>(sr)));
    const double two_pi_over_sr = 2.0 * kPi / sr;
    for (ma_uint32 i = 0; i < frames; ++i) {
        tone_env += (target - tone_env) * (target > tone_env ? attack : release);
        if (hz > 0.f) tone_freq += (hz - tone_freq) * glide;
        tone_phase += two_pi_over_sr * tone_freq;
        if (tone_phase > 2.0 * kPi) tone_phase -= 2.0 * kPi;
        const float v = tone_env * static_cast<float>(std::sin(tone_phase));
        out[2 * i] += v;
        out[2 * i + 1] += v;
    }
}

// Adds metronome clicks to an output block whose sample i plays track frame
// base + i. Stateless (each click is synthesised from its start frame), so
// seeks and pitch-shift latency need no bookkeeping. Accented clicks (bar
// starts) are higher.
void ke_audio::mix_clicks(float* out, ma_uint32 frames, int64_t base) {
    const float gain = click_gain.load(std::memory_order_relaxed);
    if (!(gain > 0.f)) return;
    const Clicks* c = clicks.load(std::memory_order_acquire);
    if (!c || c->frames.empty()) return;
    const int64_t len = static_cast<int64_t>(0.045 * sr);
    const double decay = 1.0 / (0.010 * sr);
    const int64_t end = base + static_cast<int64_t>(frames);
    auto it = std::lower_bound(c->frames.begin(), c->frames.end(), base - len);
    for (; it != c->frames.end() && *it < end; ++it) {
        const int64_t start = *it;
        const bool accent = c->accent[static_cast<size_t>(it - c->frames.begin())] != 0;
        const double w = 2.0 * 3.14159265358979323846 * (accent ? 1568.0 : 1046.5) / sr;
        const float amp = gain * (accent ? 0.9f : 0.6f);
        const int64_t from = std::max(start, base), to = std::min(start + len, end);
        for (int64_t f = from; f < to; ++f) {
            const double k = static_cast<double>(f - start);
            const float v = amp * static_cast<float>(std::sin(w * k) * std::exp(-k * decay));
            const size_t i = static_cast<size_t>(f - base);
            out[2 * i] += v;
            out[2 * i + 1] += v;
        }
    }
}

void ke_audio::data_callback(float* out, const float* in, ma_uint32 total) {
    cb_ns.store(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count(),
                std::memory_order_relaxed);
    cb_frames.store(total, std::memory_order_relaxed);
    const int calib = calib_state.load(std::memory_order_acquire);

    // ---- capture side ----
    if (in) {
        double sum = 0.0;
        for (ma_uint32 i = 0; i < total; ++i) sum += double(in[i]) * in[i];
        const float block_db = db_of_rms(std::sqrt(sum / std::max<ma_uint32>(1, total)));
        level_state = block_db > level_state ? block_db : level_state * 0.8f + block_db * 0.2f;
        input_level_db.store(level_state, std::memory_order_relaxed);

        if (calib == 1) {
            const size_t n = std::min<size_t>(total, calib_in.size() - calib_in_pos);
            std::memcpy(calib_in.data() + calib_in_pos, in, n * sizeof(float));
            calib_in_pos += n;
        }
        if (capturing.load(std::memory_order_acquire) && rb_ok) {
            const int64_t base = captured_total.load(std::memory_order_relaxed);
            // sync record for this block (lock-free SPSC ring)
            const uint64_t h = sync_head.load(std::memory_order_relaxed);
            SyncRec& r = sync_ring[h % kSyncCap];
            r.capture_index = base;
            r.track_frame = audible_frame.load(std::memory_order_acquire);
            r.playing = (playing.load(std::memory_order_acquire) && track.load(std::memory_order_acquire)) ? 1 : 0;
            sync_head.store(h + 1, std::memory_order_release);
            // audio into the ring
            ma_uint32 remaining = total;
            const float* src = in;
            while (remaining > 0) {
                ma_uint32 n = remaining;
                void* p = nullptr;
                if (ma_pcm_rb_acquire_write(&rb, &n, &p) != MA_SUCCESS || n == 0) {
                    ring_overflows.fetch_add(1, std::memory_order_relaxed);
                    break;
                }
                std::memcpy(p, src, n * sizeof(float));
                ma_pcm_rb_commit_write(&rb, n);
                src += n;
                remaining -= n;
            }
            captured_total.store(base + total, std::memory_order_release);
        }
    }

    // ---- playback side ----
    if (out) {
        if (calib == 1) {
            for (ma_uint32 i = 0; i < total; ++i) {
                const float v = calib_out_pos < calib_out.size() ? calib_out[calib_out_pos++] : 0.f;
                out[2 * i] = out[2 * i + 1] = v;
            }
            if (calib_out_pos >= calib_out.size() && calib_in_pos >= calib_in.size())
                calib_state.store(2, std::memory_order_release);
        } else {
            ma_uint32 done = 0;
            while (done < total) {
                const ma_uint32 n = std::min<ma_uint32>(total - done, kMaxBlock);
                render_block(out + 2 * done, n);
                mix_vocal_return(out + 2 * done, in ? in + done : nullptr, n);
                mix_tone(out + 2 * done, n);
                done += n;
            }
        }
    }
    cb_count.fetch_add(1, std::memory_order_release);
}

// ---------------------------------------------------------------------------------
// Workers
// ---------------------------------------------------------------------------------

double ke_audio::map_time(int64_t c, bool* on_track) {
    std::lock_guard<std::mutex> lock(sync_mutex);
    // last record with capture_index <= c
    auto it = std::upper_bound(sync_list.begin(), sync_list.end(), c,
                               [](int64_t v, const SyncRec& r) { return v < r.capture_index; });
    if (it != sync_list.begin()) {
        --it;
        if (it->playing) {
            if (on_track) *on_track = true;
            return double(it->track_frame + (c - it->capture_index)) / sr - latency_comp.load(std::memory_order_relaxed);
        }
    }
    if (on_track) *on_track = false;
    return double(c) / sr;
}

void ke_audio::push_frame(double t, float f0, float conf, float rms_db, float source) {
    std::lock_guard<std::mutex> lock(frames_mutex);
    f0_queue.push_back(static_cast<float>(t));
    f0_queue.push_back(f0);
    f0_queue.push_back(conf);
    f0_queue.push_back(rms_db);
    f0_queue.push_back(source);
}

void ke_audio::dsp_worker() {
    const int mode = capture_mode.load();
    const bool do_mpm = mode == 0 || mode == 2;
    const bool do_model = (mode == 1 || mode == 2) && model && resampler_ok;
    ke::dsp::Mpm mpm(sr, kMpmWindow, 60.f, 1500.f);
    const int64_t hop = std::max<int64_t>(1, std::llround(sr * kMpmHopSeconds));
    std::vector<float> win(kMpmWindow, 0.f);        // sliding analysis window (ends at `have`)
    int64_t have = 0;                               // capture samples consumed so far
    int64_t next_analysis = kMpmWindow;             // capture index at which the next window ends
    std::vector<float> chunk(static_cast<size_t>(kMaxBlock));
    std::vector<float> out16(static_cast<size_t>(kMaxBlock) * 4);

    while (workers_run.load(std::memory_order_acquire)) {
        // pull sync records
        {
            const uint64_t h = sync_head.load(std::memory_order_acquire);
            if (h > sync_tail) {
                if (h - sync_tail > kSyncCap) sync_tail = h - kSyncCap;   // we fell behind; skip
                std::lock_guard<std::mutex> lock(sync_mutex);
                for (; sync_tail < h; ++sync_tail) {
                    const SyncRec r = sync_ring[sync_tail % kSyncCap];
                    sync_list.push_back(r);
                    if (r.playing) {
                        std::lock_guard<std::mutex> l2(capture_mutex);
                        if (!track_synced) {
                            track_synced = true;
                            track_start_offset = double(r.track_frame - r.capture_index) / sr;
                        }
                    }
                }
                if (sync_list.size() > 20000) sync_list.erase(sync_list.begin(), sync_list.begin() + 10000);
            }
        }
        // drain audio
        bool got = false;
        {
            const ma_uint32 backlog = ma_pcm_rb_available_read(&rb);
            if (backlog > stat_backlog_max.load(std::memory_order_relaxed)) stat_backlog_max.store(backlog, std::memory_order_relaxed);
        }
        for (;;) {
            ma_uint32 n = static_cast<ma_uint32>(chunk.size());
            void* p = nullptr;
            if (ma_pcm_rb_acquire_read(&rb, &n, &p) != MA_SUCCESS || n == 0) break;
            std::memcpy(chunk.data(), p, n * sizeof(float));
            ma_pcm_rb_commit_read(&rb, n);
            got = true;
            {
                std::lock_guard<std::mutex> lock(capture_mutex);
                capture_all.insert(capture_all.end(), chunk.begin(), chunk.begin() + n);
            }
            if (do_mpm) {
                // feed the sliding window and analyse every `hop` samples
                size_t off = 0;
                while (off < n) {
                    const int64_t need = next_analysis - have;          // samples until next analysis point
                    const size_t take = static_cast<size_t>(std::min<int64_t>(need, n - off));
                    if (take >= static_cast<size_t>(kMpmWindow)) {
                        std::memcpy(win.data(), chunk.data() + off + take - kMpmWindow, kMpmWindow * sizeof(float));
                    } else if (take > 0) {
                        std::memmove(win.data(), win.data() + take, (kMpmWindow - take) * sizeof(float));
                        std::memcpy(win.data() + kMpmWindow - take, chunk.data() + off, take * sizeof(float));
                    }
                    have += take;
                    off += take;
                    if (have == next_analysis) {
                        float clarity = 0.f;
                        const auto t0 = Clock::now();
                        float f0 = mpm.detect(win.data(), &clarity);
                        const int64_t ns = std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - t0).count();
                        stat_detect_ns_total.fetch_add(ns, std::memory_order_relaxed);
                        stat_detect_count.fetch_add(1, std::memory_order_relaxed);
                        if (ns > stat_detect_ns_max.load(std::memory_order_relaxed)) stat_detect_ns_max.store(ns, std::memory_order_relaxed);
                        double sum = 0.0;
                        for (int i = 0; i < kMpmWindow; ++i) sum += double(win[i]) * win[i];
                        const float rms_db = db_of_rms(std::sqrt(sum / kMpmWindow));
                        if (clarity < 0.6f || rms_db < -60.f) f0 = 0.f;
                        const int64_t centre = have - kMpmWindow / 2;
                        push_frame(map_time(centre, nullptr), f0, clarity, rms_db, 0.f);
                        next_analysis += hop;
                    }
                }
            } else {
                have += n;
            }
            if (do_model) {
                ma_uint64 in_count = n;
                ma_uint64 out_count = out16.size();
                if (ma_resampler_process_pcm_frames(&resampler, chunk.data(), &in_count, out16.data(), &out_count) == MA_SUCCESS && out_count > 0) {
                    std::lock_guard<std::mutex> lock(m16_mutex);
                    pending16.insert(pending16.end(), out16.begin(), out16.begin() + static_cast<size_t>(out_count));
                }
                m16_cv.notify_one();
            }
        }
        if (!got) std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
}

void ke_audio::model_worker() {
    std::vector<float> buf16;        // 16 kHz samples, buf16[0] is frame `base`
    int64_t base = 0;                // frame index (256-sample hops) of buf16[0]
    int64_t emitted = 0;             // frames emitted so far
    std::vector<float> f0, conf;
    const double ratio = double(sr) / ke::swiftf0::kSampleRate;
    float fmin = ke::swiftf0::kFminDefault, fmax = ke::swiftf0::kFmaxDefault;

    while (true) {
        {
            std::unique_lock<std::mutex> lock(m16_mutex);
            m16_cv.wait_for(lock, std::chrono::milliseconds(20), [&] { return !pending16.empty() || !workers_run.load(); });
            if (!workers_run.load() && pending16.empty()) break;
            buf16.insert(buf16.end(), pending16.begin(), pending16.end());
            pending16.clear();
        }
        const int64_t available = base + static_cast<int64_t>(buf16.size() / ke::swiftf0::kHop);
        const int64_t last = available - kModelLookahead;        // frames final so far
        if (last - emitted < kModelEmitFrames) continue;
        int64_t start = std::min<int64_t>(emitted - kModelLeftFrames, available - kModelWindowFrames);
        start = std::max<int64_t>(start, base);
        const size_t s0 = static_cast<size_t>((start - base) * ke::swiftf0::kHop);
        const size_t s1 = static_cast<size_t>((available - base) * ke::swiftf0::kHop);
        const auto t0 = Clock::now();
        const int rc = model->run_window(buf16.data() + s0, s1 - s0, fmin, fmax, f0, conf);
        {
            const int64_t ns = std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - t0).count();
            stat_model_ns_total.fetch_add(ns, std::memory_order_relaxed);
            stat_model_count.fetch_add(1, std::memory_order_relaxed);
            if (ns > stat_model_ns_max.load(std::memory_order_relaxed)) stat_model_ns_max.store(ns, std::memory_order_relaxed);
        }
        if (rc != KE_OK) {
            KE_LOGW("swiftf0 live: model run failed: %s", ke_last_error());
            emitted = last;
            continue;
        }
        for (int64_t k = emitted; k < last; ++k) {
            const size_t idx = static_cast<size_t>(k - start);
            if (idx >= conf.size()) break;
            const float c = conf[idx];
            const float hz = c >= ke::swiftf0::kVoicedThreshold ? f0[idx] : 0.f;
            const float loud = ke::swiftf0::loudness_db(buf16.data() + s0, s1 - s0, idx);
            const int64_t capture_index = static_cast<int64_t>(std::llround(double(k * ke::swiftf0::kHop) * ratio));
            push_frame(map_time(capture_index, nullptr), hz, c, loud, 1.f);
        }
        emitted = last;
        // prune: keep enough left context for the next window
        const int64_t keep_from = std::max<int64_t>(base, emitted - kModelWindowFrames - kModelLeftFrames);
        if (keep_from > base) {
            buf16.erase(buf16.begin(), buf16.begin() + static_cast<size_t>((keep_from - base) * ke::swiftf0::kHop));
            base = keep_from;
        }
    }
}

// ---------------------------------------------------------------------------------
// Helpers used by the API thread
// ---------------------------------------------------------------------------------

void ke_audio::wait_callback_cycles(int n) {
    // Waits until the device callback has run n more times (so it no longer touches
    // state we are about to free/reset). Bounded in case the device is stalled.
    if (!dev_ok || !ma_device_is_started(&dev)) return;
    const uint64_t target = cb_count.load(std::memory_order_acquire) + static_cast<uint64_t>(n);
    const auto deadline = Clock::now() + std::chrono::milliseconds(500);
    while (cb_count.load(std::memory_order_acquire) < target && Clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
}

int ke_audio::swap_track(Track* t) {
    playing.store(false, std::memory_order_release);
    seek_request.store(0, std::memory_order_release);
    Track* old = track.exchange(t, std::memory_order_acq_rel);
    wait_callback_cycles(2);
    delete old;
    audible_frame.store(0, std::memory_order_release);
    return KE_OK;
}

// ---------------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------------

extern "C" {

KE_API int ke_audio_list_devices_json(char* out, size_t cap, size_t* needed) {
    ma_context ctx;
    ma_result r = ma_context_init(nullptr, 0, nullptr, &ctx);
    if (r != MA_SUCCESS) return ke::fail(KE_ERR_AUDIO_DEVICE, "ma_context_init: %s", ma_err(r).c_str());
    ma_device_info* pb = nullptr; ma_device_info* cp = nullptr;
    ma_uint32 npb = 0, ncp = 0;
    r = ma_context_get_devices(&ctx, &pb, &npb, &cp, &ncp);
    if (r != MA_SUCCESS) {
        ma_context_uninit(&ctx);
        return ke::fail(KE_ERR_AUDIO_DEVICE, "ma_context_get_devices: %s", ma_err(r).c_str());
    }
    json j;
    j["backend"] = ma_get_backend_name(ctx.backend);
    j["capture"] = json::array();
    j["playback"] = json::array();
    for (ma_uint32 i = 0; i < ncp; ++i)
        j["capture"].push_back({{"id", encode_device_id(cp[i].id)}, {"name", cp[i].name}, {"default", cp[i].isDefault != 0}});
    for (ma_uint32 i = 0; i < npb; ++i)
        j["playback"].push_back({{"id", encode_device_id(pb[i].id)}, {"name", pb[i].name}, {"default", pb[i].isDefault != 0}});
    ma_context_uninit(&ctx);
    return ke::write_out_string(j.dump(), out, cap, needed);
}

KE_API int ke_audio_create(const char* capture_device_id, const char* playback_device_id, int sample_rate, ke_audio** out) {
    if (!out) return ke::fail(KE_ERR_INVALID_ARG, "out is null");
    *out = nullptr;
    if (sample_rate < 8000 || sample_rate > 192000) return ke::fail(KE_ERR_INVALID_ARG, "unsupported sample rate %d", sample_rate);
    std::unique_ptr<ke_audio> a(new ke_audio());
    a->sr = sample_rate;

    ma_result r = ma_context_init(nullptr, 0, nullptr, &a->ctx);
    if (r != MA_SUCCESS) return ke::fail(KE_ERR_AUDIO_DEVICE, "ma_context_init: %s", ma_err(r).c_str());
    a->ctx_ok = true;

    ma_device_id cap_id, pb_id;
    bool have_cap = capture_device_id && *capture_device_id;
    bool have_pb = playback_device_id && *playback_device_id;
    if (have_cap && !decode_device_id(capture_device_id, cap_id)) return ke::fail(KE_ERR_INVALID_ARG, "bad capture device id");
    if (have_pb && !decode_device_id(playback_device_id, pb_id)) return ke::fail(KE_ERR_INVALID_ARG, "bad playback device id");

    ma_device_config cfg = ma_device_config_init(ma_device_type_duplex);
    cfg.sampleRate = static_cast<ma_uint32>(sample_rate);
    cfg.performanceProfile = ma_performance_profile_low_latency;
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.playback.pDeviceID = have_pb ? &pb_id : nullptr;
    cfg.capture.format = ma_format_f32;
    cfg.capture.channels = 1;
    cfg.capture.pDeviceID = have_cap ? &cap_id : nullptr;
    cfg.dataCallback = ke_ma_callback;
    cfg.pUserData = a.get();
    r = ma_device_init(&a->ctx, &cfg, &a->dev);
    if (r != MA_SUCCESS) return ke::fail(KE_ERR_AUDIO_DEVICE, "ma_device_init (duplex, %d Hz): %s", sample_rate, ma_err(r).c_str());
    a->dev_ok = true;
    if (a->dev.playback.internalSampleRate)
        a->out_latency = double(a->dev.playback.internalPeriodSizeInFrames) * a->dev.playback.internalPeriods / a->dev.playback.internalSampleRate;
    if (a->dev.capture.internalSampleRate)
        a->in_latency = double(a->dev.capture.internalPeriodSizeInFrames) * a->dev.capture.internalPeriods / a->dev.capture.internalSampleRate;
    a->latency_comp.store(a->out_latency);

    // preallocate everything the callback touches
    a->stretch.presetDefault(2, static_cast<float>(sample_rate), true);
    a->stretch.setTransposeSemitones(0.f);
    a->stretch_latency = a->stretch.inputLatency() + a->stretch.outputLatency();
    a->st_in_l.assign(kMaxBlock, 0.f); a->st_in_r.assign(kMaxBlock, 0.f);
    a->st_out_l.assign(kMaxBlock, 0.f); a->st_out_r.assign(kMaxBlock, 0.f);
    a->preroll_l.assign(static_cast<size_t>(a->stretch.seekLength()), 0.f);
    a->preroll_r.assign(static_cast<size_t>(a->stretch.seekLength()), 0.f);
    a->vr_dry.assign(kMaxBlock, 0.f); a->vr_wl.assign(kMaxBlock, 0.f); a->vr_wr.assign(kMaxBlock, 0.f);
    if (sample_rate <= ke::HallReverb::kMaxSampleRate) a->reverb = std::make_unique<ke::HallReverb>(sample_rate);
    r = ma_pcm_rb_init(ma_format_f32, 1, static_cast<ma_uint32>(kRingSeconds * sample_rate), nullptr, nullptr, &a->rb);
    if (r != MA_SUCCESS) return ke::fail(KE_ERR_AUDIO_DEVICE, "ma_pcm_rb_init: %s", ma_err(r).c_str());
    a->rb_ok = true;
    // calibration click pattern: 5 Hann-windowed 1.5 kHz bursts (2 ms) 200 ms apart
    a->calib_out.assign(static_cast<size_t>(kCalibSeconds * sample_rate), 0.f);
    a->calib_in.assign(static_cast<size_t>(kCalibSeconds * sample_rate), 0.f);
    {
        const int len = std::max(8, static_cast<int>(0.002 * sample_rate));
        for (int k = 0; k < kCalibClicks; ++k) {
            const size_t s0 = static_cast<size_t>((kCalibFirstClick + k * kCalibClickSpacing) * sample_rate);
            for (int i = 0; i < len && s0 + i < a->calib_out.size(); ++i) {
                const double w = 0.5 - 0.5 * std::cos(2.0 * kPi * i / (len - 1));
                a->calib_out[s0 + i] = static_cast<float>(0.6 * w * std::sin(2.0 * kPi * 1500.0 * i / sample_rate));
            }
        }
    }

    r = ma_device_start(&a->dev);
    if (r != MA_SUCCESS) return ke::fail(KE_ERR_AUDIO_DEVICE, "ma_device_start: %s", ma_err(r).c_str());
    char pbname[256] = {0}, capname[256] = {0};
    ma_device_get_name(&a->dev, ma_device_type_playback, pbname, sizeof(pbname), nullptr);
    ma_device_get_name(&a->dev, ma_device_type_capture, capname, sizeof(capname), nullptr);
    KE_LOGI("audio: %s | capture \"%s\" (%u Hz native, period %u x %u) | playback \"%s\" (%u Hz native, period %u x %u) | %d Hz, latency in %.1f ms out %.1f ms, stretch latency %d frames",
            ma_get_backend_name(a->ctx.backend), capname, a->dev.capture.internalSampleRate,
            a->dev.capture.internalPeriodSizeInFrames, a->dev.capture.internalPeriods, pbname,
            a->dev.playback.internalSampleRate, a->dev.playback.internalPeriodSizeInFrames, a->dev.playback.internalPeriods,
            sample_rate, a->in_latency * 1000.0, a->out_latency * 1000.0, a->stretch_latency);
    *out = a.release();
    return KE_OK;
}

KE_API void ke_audio_destroy(ke_audio* a) {
    if (!a) return;
    ke_audio_stop_capture(a);
    delete a;   // ~ke_audio uninitialises the device (joining the callback thread) and the context
}

KE_API int ke_audio_get_latency(ke_audio* a, double* in, double* out) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    if (in) *in = a->in_latency;
    if (out) *out = a->out_latency;
    return KE_OK;
}

// ---- track ----

KE_API int ke_audio_load_track(ke_audio* a, const char* wav_path) {
    if (!a || !wav_path) return ke::fail(KE_ERR_INVALID_ARG, "ke_audio_load_track: null argument");
    ke::AudioBuffer buf;
    int rc = ke::read_wav(wav_path, buf);
    if (rc != KE_OK) return rc;
    if (buf.frames() == 0) return ke::fail(KE_ERR_INVALID_ARG, "track %s is empty", wav_path);
    ke::AudioBuffer st = ke::with_channels(buf, 2);
    auto t = std::make_unique<Track>();
    t->sample_rate = a->sr;
    t->left = buf.sample_rate == a->sr ? std::move(st.planes[0]) : ke::resample(st.planes[0], buf.sample_rate, a->sr);
    t->right = buf.sample_rate == a->sr ? std::move(st.planes[1]) : ke::resample(st.planes[1], buf.sample_rate, a->sr);
    t->frames = static_cast<int64_t>(std::min(t->left.size(), t->right.size()));
    KE_LOGI("audio: loaded %s (%d Hz, %d ch, %.2f s) -> %d Hz", wav_path, buf.sample_rate, buf.channels, buf.duration(), a->sr);
    std::lock_guard<std::mutex> lock(a->api_mutex);
    return a->swap_track(t.release());
}

KE_API int ke_audio_unload_track(ke_audio* a) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    std::lock_guard<std::mutex> lock(a->api_mutex);
    return a->swap_track(nullptr);
}

KE_API double ke_audio_track_duration(ke_audio* a) {
    if (!a) return 0.0;
    Track* t = a->track.load(std::memory_order_acquire);
    return t ? double(t->frames) / a->sr : 0.0;
}

KE_API int ke_audio_play(ke_audio* a) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    if (!a->track.load(std::memory_order_acquire)) return ke::fail(KE_ERR_STATE, "no track loaded");
    if (a->calib_state.load() == 1) return ke::fail(KE_ERR_STATE, "calibration in progress");
    a->playing.store(true, std::memory_order_release);
    return KE_OK;
}

KE_API int ke_audio_pause(ke_audio* a) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    a->playing.store(false, std::memory_order_release);
    return KE_OK;
}

KE_API int ke_audio_seek(ke_audio* a, double seconds) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    Track* t = a->track.load(std::memory_order_acquire);
    if (!t) return ke::fail(KE_ERR_STATE, "no track loaded");
    const int64_t f = std::clamp<int64_t>(static_cast<int64_t>(std::llround(seconds * a->sr)), 0, t->frames);
    a->seek_request.store(f, std::memory_order_release);
    if (!a->playing.load(std::memory_order_acquire)) {
        // The callback only consumes seek requests while playing; reflect it immediately
        // so ke_audio_position() answers correctly while paused. The request is still
        // applied by the callback when play resumes.
        a->audible_frame.store(f, std::memory_order_release);
    }
    return KE_OK;
}

KE_API int ke_audio_is_playing(ke_audio* a) { return a && a->playing.load(std::memory_order_acquire) ? 1 : 0; }

KE_API double ke_audio_position(ke_audio* a) {
    if (!a) return 0.0;
    const int64_t f = a->audible_frame.load(std::memory_order_acquire);
    double pos = double(f) / a->sr;
    if (a->playing.load(std::memory_order_acquire)) {
        // frames are exact per callback; interpolate inside the current period for smooth UI
        const int64_t now = std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count();
        const double el = double(now - a->cb_ns.load(std::memory_order_relaxed)) * 1e-9;
        const double period = double(a->cb_frames.load(std::memory_order_relaxed)) / a->sr;
        pos += std::clamp(el, 0.0, period);
    }
    Track* t = a->track.load(std::memory_order_acquire);
    if (t) pos = std::min(pos, double(t->frames) / a->sr);
    return pos;
}

KE_API int ke_audio_set_volume(ke_audio* a, float gain) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    if (!(gain >= 0.f) || gain > 10.f) return ke::fail(KE_ERR_INVALID_ARG, "gain out of range");
    a->volume.store(gain, std::memory_order_relaxed);
    return KE_OK;
}

KE_API int ke_audio_set_clicks(ke_audio* a, const double* times, const int* accents, int n) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    if (n < 0 || (n > 0 && !times)) return ke::fail(KE_ERR_INVALID_ARG, "bad click list");
    auto* c = new Clicks();
    c->frames.reserve(static_cast<size_t>(n));
    c->accent.reserve(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) {
        if (!(times[i] >= 0.0)) continue;
        c->frames.push_back(static_cast<int64_t>(std::llround(times[i] * a->sr)));
        c->accent.push_back(accents && accents[i] ? 1 : 0);
    }
    // Keep accents paired with frames while sorting.
    std::vector<size_t> order(c->frames.size());
    for (size_t i = 0; i < order.size(); ++i) order[i] = i;
    std::sort(order.begin(), order.end(), [&](size_t x, size_t y) { return c->frames[x] < c->frames[y]; });
    Clicks* sorted = new Clicks();
    for (size_t i : order) {
        sorted->frames.push_back(c->frames[i]);
        sorted->accent.push_back(c->accent[i]);
    }
    delete c;
    Clicks* old = a->clicks.exchange(sorted, std::memory_order_acq_rel);
    if (old) {
        a->wait_callback_cycles(2);  // the callback may still be reading it
        delete old;
    }
    return KE_OK;
}

KE_API int ke_audio_set_click_gain(ke_audio* a, float gain) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    if (!(gain >= 0.f) || gain > 4.f) return ke::fail(KE_ERR_INVALID_ARG, "click gain out of range");
    a->click_gain.store(gain, std::memory_order_relaxed);
    return KE_OK;
}

KE_API int ke_audio_set_vocal_return(ke_audio* a, int on) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    a->vocal_return.store(on != 0, std::memory_order_relaxed);
    return KE_OK;
}

KE_API int ke_audio_set_reverb(ke_audio* a, int on, float mix) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    if (!(mix >= 0.f && mix <= 1.f)) return ke::fail(KE_ERR_INVALID_ARG, "reverb mix out of range");
    a->reverb_mix.store(mix, std::memory_order_relaxed);
    a->reverb_on.store(on != 0, std::memory_order_relaxed);
    return KE_OK;
}

KE_API int ke_audio_set_tone(ke_audio* a, float hz, float gain) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    if (!(hz >= 0.f && hz <= 20000.f)) return ke::fail(KE_ERR_INVALID_ARG, "tone frequency out of range");
    if (!(gain >= 0.f && gain <= 1.f)) return ke::fail(KE_ERR_INVALID_ARG, "tone gain out of range");
    a->tone_gain.store(gain, std::memory_order_relaxed);
    a->tone_hz.store(hz, std::memory_order_relaxed);
    return KE_OK;
}

KE_API int ke_audio_set_pitch_shift(ke_audio* a, float semitones) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    if (std::isnan(semitones) || std::fabs(semitones) > 24.f) return ke::fail(KE_ERR_INVALID_ARG, "semitones out of range");
    a->pitch_semitones.store(semitones, std::memory_order_relaxed);
    return KE_OK;
}

// ---- capture ----

KE_API int ke_audio_start_capture(ke_audio* a, ke_runtime* rt, const char* model_path, int mode) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    if (mode < 0 || mode > 2) return ke::fail(KE_ERR_INVALID_ARG, "mode must be 0, 1 or 2");
    std::lock_guard<std::mutex> lock(a->api_mutex);
    if (a->capturing.load()) return ke::fail(KE_ERR_STATE, "already capturing");
    if (a->calib_state.load() == 1) return ke::fail(KE_ERR_STATE, "calibration in progress");
    a->model.reset();
    if (mode == 1 || mode == 2) {
        if (!rt || !model_path) return ke::fail(KE_ERR_INVALID_ARG, "mode %d needs a runtime and a SwiftF0 model path", mode);
        std::string err;
        a->model = ke::swiftf0::Model::load(rt, model_path, &err);
        if (!a->model) return ke::fail_str(KE_ERR_MODEL, "swiftf0: " + err);
        if (!a->resampler_ok) {
            ma_resampler_config rc = ma_resampler_config_init(ma_format_f32, 1, static_cast<ma_uint32>(a->sr),
                                                              ke::swiftf0::kSampleRate, ma_resample_algorithm_linear);
            rc.linear.lpfOrder = MA_MAX_FILTER_ORDER;
            ma_result r = ma_resampler_init(&rc, nullptr, &a->resampler);
            if (r != MA_SUCCESS) return ke::fail(KE_ERR_INTERNAL, "ma_resampler_init: %s", ma_err(r).c_str());
            a->resampler_ok = true;
        } else {
            ma_resampler_reset(&a->resampler);
        }
    }
    // reset state
    {
        std::lock_guard<std::mutex> l1(a->capture_mutex);
        a->capture_all.clear();
        a->capture_all.reserve(static_cast<size_t>(a->sr) * 60);
        a->track_synced = false;
        a->track_start_offset = 0.0;
    }
    {
        std::lock_guard<std::mutex> l2(a->frames_mutex);
        a->f0_queue.clear();
        a->f0_read = 0;
    }
    {
        std::lock_guard<std::mutex> l3(a->sync_mutex);
        a->sync_list.clear();
    }
    a->pending16.clear();
    ma_pcm_rb_reset(&a->rb);
    a->captured_total.store(0);
    a->ring_overflows.store(0);
    a->sync_head.store(0);
    a->sync_tail = 0;
    a->capture_mode.store(mode);
    a->stat_detect_ns_max.store(0); a->stat_detect_ns_total.store(0); a->stat_detect_count.store(0);
    a->stat_model_ns_max.store(0); a->stat_model_ns_total.store(0); a->stat_model_count.store(0);
    a->stat_backlog_max.store(0);
    a->workers_run.store(true);
    a->dsp_thread = std::thread([a] { a->dsp_worker(); });
    if (a->model) a->model_thread = std::thread([a] { a->model_worker(); });
    a->capturing.store(true, std::memory_order_release);
    KE_LOGI("audio: capture started (mode %d%s)", mode, a->model ? ", SwiftF0" : "");
    return KE_OK;
}

KE_API int ke_audio_stop_capture(ke_audio* a) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    std::lock_guard<std::mutex> lock(a->api_mutex);
    if (!a->capturing.load()) return KE_OK;
    a->capturing.store(false, std::memory_order_release);
    a->wait_callback_cycles(2);           // callback no longer writes the ring
    std::this_thread::sleep_for(std::chrono::milliseconds(10));   // let the dsp worker drain
    a->workers_run.store(false, std::memory_order_release);
    a->m16_cv.notify_all();
    if (a->dsp_thread.joinable()) a->dsp_thread.join();
    if (a->model_thread.joinable()) a->model_thread.join();
    const uint32_t ov = a->ring_overflows.load();
    if (ov) KE_LOGW("audio: capture ring overflowed %u times (worker starved)", ov);
    const int64_t nd = a->stat_detect_count.load(), nm = a->stat_model_count.load();
    KE_LOGI("audio: capture stopped after %.2f s | mpm %lld calls, mean %.2f ms, max %.2f ms | swiftf0 %lld runs, mean %.2f ms, max %.2f ms | max ring backlog %.1f ms",
            double(a->captured_total.load()) / a->sr,
            static_cast<long long>(nd), nd ? a->stat_detect_ns_total.load() / 1e6 / nd : 0.0, a->stat_detect_ns_max.load() / 1e6,
            static_cast<long long>(nm), nm ? a->stat_model_ns_total.load() / 1e6 / nm : 0.0, a->stat_model_ns_max.load() / 1e6,
            double(a->stat_backlog_max.load()) * 1000.0 / a->sr);
    return KE_OK;
}

KE_API int ke_audio_is_capturing(ke_audio* a) { return a && a->capturing.load(std::memory_order_acquire) ? 1 : 0; }

KE_API int ke_audio_read_f0(ke_audio* a, float* out, int max_frames) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    if (!out || max_frames <= 0) return 0;
    std::lock_guard<std::mutex> lock(a->frames_mutex);
    const size_t avail = (a->f0_queue.size() - a->f0_read) / 5;
    const size_t n = std::min<size_t>(avail, static_cast<size_t>(max_frames));
    if (n) std::memcpy(out, a->f0_queue.data() + a->f0_read, n * 5 * sizeof(float));
    a->f0_read += n * 5;
    if (a->f0_read == a->f0_queue.size()) { a->f0_queue.clear(); a->f0_read = 0; }
    else if (a->f0_read > 4096 * 5) { a->f0_queue.erase(a->f0_queue.begin(), a->f0_queue.begin() + a->f0_read); a->f0_read = 0; }
    return static_cast<int>(n);
}

KE_API int ke_audio_set_latency_compensation(ke_audio* a, double seconds) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    if (std::isnan(seconds) || seconds < -1.0 || seconds > 5.0) return ke::fail(KE_ERR_INVALID_ARG, "latency compensation out of range");
    a->latency_comp.store(seconds, std::memory_order_relaxed);
    return KE_OK;
}

KE_API double ke_audio_capture_elapsed(ke_audio* a) {
    if (!a) return 0.0;
    return double(a->captured_total.load(std::memory_order_acquire)) / a->sr;
}

KE_API int ke_audio_save_capture(ke_audio* a, const char* wav_path) {
    if (!a || !wav_path) return ke::fail(KE_ERR_INVALID_ARG, "ke_audio_save_capture: null argument");
    ke::AudioBuffer buf;
    double offset = 0.0;
    bool synced = false;
    {
        std::lock_guard<std::mutex> lock(a->capture_mutex);
        buf.sample_rate = a->sr;
        buf.channels = 1;
        buf.planes.push_back(a->capture_all);
        offset = a->track_start_offset;
        synced = a->track_synced;
    }
    if (buf.frames() == 0) return ke::fail(KE_ERR_STATE, "nothing captured");
    int rc = ke::write_wav_f32(wav_path, buf);
    if (rc != KE_OK) return rc;
    json j;
    j["track_start_offset"] = offset;
    j["latency"] = a->latency_comp.load();
    j["track_synced"] = synced;
    j["sample_rate"] = a->sr;
    j["frames"] = buf.frames();
    j["duration"] = buf.duration();
    j["input_latency"] = a->in_latency;
    j["output_latency"] = a->out_latency;
    j["note"] = "capture sample i corresponds to track time track_start_offset + i / sample_rate - latency";
    const std::string side = std::string(wav_path) + ".json";
    FILE* fp = std::fopen(side.c_str(), "wb");
    if (!fp) return ke::fail(KE_ERR_IO, "cannot write %s", side.c_str());
    const std::string s = j.dump(2);
    std::fwrite(s.data(), 1, s.size(), fp);
    std::fclose(fp);
    KE_LOGI("audio: saved %.2f s capture to %s (+ .json)", buf.duration(), wav_path);
    return KE_OK;
}

KE_API int ke_audio_calibrate_latency(ke_audio* a, double* roundtrip_seconds) {
    if (!a) return ke::fail(KE_ERR_INVALID_ARG, "audio is null");
    if (roundtrip_seconds) *roundtrip_seconds = 0.0;
    std::lock_guard<std::mutex> lock(a->api_mutex);
    if (a->playing.load()) return ke::fail(KE_ERR_STATE, "cannot calibrate while a track is playing");
    if (a->capturing.load()) return ke::fail(KE_ERR_STATE, "cannot calibrate while capturing");
    if (a->calib_state.load() == 1) return ke::fail(KE_ERR_STATE, "calibration already running");
    std::fill(a->calib_in.begin(), a->calib_in.end(), 0.f);
    a->calib_out_pos = a->calib_in_pos = 0;
    a->calib_state.store(1, std::memory_order_release);
    const auto deadline = Clock::now() + std::chrono::milliseconds(static_cast<int>(kCalibSeconds * 1000) + 2000);
    while (a->calib_state.load(std::memory_order_acquire) == 1 && Clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    const bool finished = a->calib_state.load() == 2;
    a->calib_state.store(0, std::memory_order_release);
    a->wait_callback_cycles(1);
    if (!finished) return ke::fail(KE_ERR_AUDIO_DEVICE, "calibration timed out (device not running?)");

    // Matched filter of the recording against the click pattern (only the non-zero pattern samples).
    const std::vector<float>& pat = a->calib_out;
    const std::vector<float>& rec = a->calib_in;
    std::vector<size_t> nz;
    for (size_t i = 0; i < pat.size(); ++i) if (pat[i] != 0.f) nz.push_back(i);
    const size_t max_lag = static_cast<size_t>(kCalibMaxLag * a->sr);
    std::vector<double> corr(max_lag, 0.0);
    double rec_peak = 0.0;
    for (float v : rec) rec_peak = std::max(rec_peak, double(std::fabs(v)));
    for (size_t lag = 0; lag < max_lag; ++lag) {
        double s = 0.0;
        for (size_t i : nz) { const size_t k = i + lag; if (k < rec.size()) s += double(pat[i]) * rec[k]; }
        corr[lag] = std::fabs(s);
    }
    size_t best = 0;
    double peak = 0.0, mean = 0.0;
    for (size_t lag = 0; lag < max_lag; ++lag) { if (corr[lag] > peak) { peak = corr[lag]; best = lag; } mean += corr[lag]; }
    mean /= std::max<size_t>(1, max_lag);
    const double prominence = mean > 0 ? peak / mean : 0.0;
    if (rec_peak < 1e-4 || prominence < 6.0)
        return ke::fail(KE_ERR_AUDIO_DEVICE, "no click detected in the recording (input peak %.1f dBFS, peak/mean %.1f): is the microphone enabled and able to hear the speakers?",
                        db_of_rms(rec_peak), prominence);
    // Per-click lag within +-5 ms of the global peak, then the median.
    const int half = static_cast<int>(0.005 * a->sr);
    const int len = std::max(8, static_cast<int>(0.002 * a->sr));
    std::vector<double> lags;
    for (int k = 0; k < kCalibClicks; ++k) {
        const size_t s0 = static_cast<size_t>((kCalibFirstClick + k * kCalibClickSpacing) * a->sr);
        double bp = -1.0; size_t bl = best;
        for (int d = -half; d <= half; ++d) {
            const long lag = static_cast<long>(best) + d;
            if (lag < 0) continue;
            double s = 0.0;
            for (int i = 0; i < len; ++i) { const size_t kk = s0 + i + static_cast<size_t>(lag); if (kk < rec.size()) s += double(pat[s0 + i]) * rec[kk]; }
            s = std::fabs(s);
            if (s > bp) { bp = s; bl = static_cast<size_t>(lag); }
        }
        lags.push_back(double(bl) / a->sr);
    }
    std::sort(lags.begin(), lags.end());
    const double median = lags[lags.size() / 2];
    KE_LOGI("audio: calibration round trip %.1f ms (per click: %.1f %.1f %.1f %.1f %.1f ms, peak/mean %.1f, input peak %.1f dBFS)",
            median * 1000.0, lags[0] * 1000, lags[1] * 1000, lags[2] * 1000, lags[3] * 1000, lags[4] * 1000, prominence, db_of_rms(rec_peak));
    if (roundtrip_seconds) *roundtrip_seconds = median;
    return KE_OK;
}

KE_API float ke_audio_input_level_db(ke_audio* a) {
    return a ? a->input_level_db.load(std::memory_order_relaxed) : -100.f;
}

}  // extern "C"
