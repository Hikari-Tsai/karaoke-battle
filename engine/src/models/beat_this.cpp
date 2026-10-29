// Beat This! beat / downbeat tracking. See beat_this.h for the pipeline.
#include "beat_this.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdio>
#include <fstream>
#include <memory>

#include "../core/error.h"
#include "../core/ort_runtime.h"
#include "../core/resample.h"
#include "../core/wav.h"
#include "nlohmann/json.hpp"
#include "pocketfft/pocketfft_hdronly.h"

namespace ke::beat_this {
namespace {

struct Frontend {
    int sample_rate = 0, n_fft = 0, hop = 0, n_mels = 0;
    std::vector<double> window;
    // Sparse mel filters: per mel band, (bin, weight) pairs.
    std::vector<std::vector<std::pair<int, double>>> mel;
};

int load_frontend(const std::string& path, Frontend& f) {
    std::ifstream in(path);
    if (!in) return fail(KE_ERR_MODEL, "beat_this: cannot open %s", path.c_str());
    nlohmann::json j;
    try {
        in >> j;
        f.sample_rate = j.at("sample_rate").get<int>();
        f.n_fft = j.at("n_fft").get<int>();
        f.hop = j.at("hop_length").get<int>();
        f.n_mels = j.at("n_mels").get<int>();
        f.window = j.at("window").get<std::vector<double>>();
        const auto& filters = j.at("mel_filters");
        f.mel.resize(filters.size());
        for (size_t m = 0; m < filters.size(); ++m) {
            const auto& row = filters[m];
            for (size_t k = 0; k < row.size(); ++k) {
                const double v = row[k].get<double>();
                if (v != 0.0) f.mel[m].emplace_back(static_cast<int>(k), v);
            }
        }
    } catch (const std::exception& e) {
        return fail(KE_ERR_MODEL, "beat_this: bad frontend.json: %s", e.what());
    }
    if (f.sample_rate != kSampleRate || f.hop * kFps != kSampleRate || f.n_mels != 128 ||
        static_cast<int>(f.window.size()) != f.n_fft || static_cast<int>(f.mel.size()) != f.n_mels)
        return fail(KE_ERR_MODEL, "beat_this: unexpected frontend constants");
    return KE_OK;
}

// torchaudio-equivalent log-mel: centred frames with reflect padding.
std::vector<float> log_mel(const std::vector<float>& audio, const Frontend& f, long& frames_out) {
    const long n = static_cast<long>(audio.size());
    const int nfft = f.n_fft;
    const long frames = n / f.hop + 1;
    frames_out = frames;
    std::vector<float> out(static_cast<size_t>(frames) * f.n_mels);
    std::vector<double> buf(nfft);
    std::vector<std::complex<double>> spec(nfft / 2 + 1);
    std::vector<double> mag(nfft / 2 + 1);
    const double scale = 1.0 / std::sqrt(static_cast<double>(nfft));
    pocketfft::shape_t shape{static_cast<size_t>(nfft)};
    pocketfft::stride_t sin{sizeof(double)}, sout{sizeof(std::complex<double>)};
    for (long t = 0; t < frames; ++t) {
        for (int j = 0; j < nfft; ++j) {
            long i = t * f.hop + j - nfft / 2;
            if (i < 0) i = -i;
            if (i >= n) i = 2 * n - 2 - i;
            i = std::clamp(i, 0L, n - 1);
            buf[j] = static_cast<double>(audio[static_cast<size_t>(i)]) * f.window[j];
        }
        pocketfft::r2c<double>(shape, sin, sout, 0, true, buf.data(), spec.data(), 1.0);
        for (int k = 0; k <= nfft / 2; ++k) mag[k] = std::abs(spec[k]) * scale;
        float* row = out.data() + static_cast<size_t>(t) * f.n_mels;
        for (int m = 0; m < f.n_mels; ++m) {
            double sum = 0;
            for (const auto& [k, w] : f.mel[m]) sum += mag[k] * w;
            row[m] = static_cast<float>(std::log1p(1000.0 * sum));
        }
    }
    return out;
}

void write_json(const std::string& path, const Result& r, int& rc) {
    FILE* fp = std::fopen(path.c_str(), "wb");
    if (!fp) {
        rc = fail(KE_ERR_IO, "cannot write %s", path.c_str());
        return;
    }
    std::string s;
    char tmp[64];
    s += "{\"fps\":50,\"model\":\"beat-this-final0\",";
    if (r.bpm > 0) {
        std::snprintf(tmp, sizeof(tmp), "\"bpm\":%.3f,", r.bpm);
        s += tmp;
    } else {
        s += "\"bpm\":null,";
    }
    if (r.signature_beats > 0) {
        std::snprintf(tmp, sizeof(tmp), "\"signature_beats\":%d,", r.signature_beats);
        s += tmp;
    } else {
        s += "\"signature_beats\":null,";
    }
    s += "\"tempo_mode\":\"" + r.tempo_mode + "\",\"beats\":[";
    for (size_t i = 0; i < r.beats.size(); ++i) {
        std::snprintf(tmp, sizeof(tmp), "%s%.4f", i ? "," : "", r.beats[i]);
        s += tmp;
    }
    s += "],\"downbeats\":[";
    for (size_t i = 0; i < r.downbeats.size(); ++i) {
        std::snprintf(tmp, sizeof(tmp), "%s%.4f", i ? "," : "", r.downbeats[i]);
        s += tmp;
    }
    s += "]}\n";
    const size_t written = std::fwrite(s.data(), 1, s.size(), fp);
    std::fclose(fp);
    if (written != s.size()) rc = fail(KE_ERR_IO, "short write to %s", path.c_str());
}

}  // namespace

std::vector<long> chunk_starts(long frames) {
    std::vector<long> starts;
    for (long s = -kBorder; s < frames - kBorder; s += kChunk - 2 * kBorder) starts.push_back(s);
    if (frames > kChunk - 2 * kBorder && !starts.empty()) starts.back() = frames - (kChunk - kBorder);
    return starts;
}

std::vector<double> pick_peaks(const std::vector<float>& v) {
    const long n = static_cast<long>(v.size());
    std::vector<long> cand;
    for (long i = 0; i < n; ++i) {
        if (!(v[i] > 0.f)) continue;
        float mx = -INFINITY;
        for (long j = std::max(0L, i - 3); j <= std::min(n - 1, i + 3); ++j) mx = std::max(mx, v[j]);
        if (v[i] == mx) cand.push_back(i);
    }
    std::vector<double> out;
    if (cand.empty()) return out;
    double mean = static_cast<double>(cand[0]);
    int count = 1;
    for (size_t c = 1; c < cand.size(); ++c) {
        const double p = static_cast<double>(cand[c]);
        if (p - mean <= 1) {
            ++count;
            mean += (p - mean) / count;
        } else {
            out.push_back(mean / kFps);
            mean = p;
            count = 1;
        }
    }
    out.push_back(mean / kFps);
    return out;
}

void postprocess(const std::vector<float>& beat, const std::vector<float>& downbeat, Result& out) {
    out.beats = pick_peaks(beat);
    const auto raw = pick_peaks(downbeat);
    out.downbeats.clear();
    for (double t : raw) {
        double snapped = t;
        if (!out.beats.empty()) {
            snapped = out.beats[0];
            for (double b : out.beats)
                if (std::fabs(b - t) < std::fabs(snapped - t)) snapped = b;
        }
        if (std::find(out.downbeats.begin(), out.downbeats.end(), snapped) == out.downbeats.end())
            out.downbeats.push_back(snapped);
    }
    std::sort(out.downbeats.begin(), out.downbeats.end());
}

void estimate_tempo(Result& r) {
    const auto& b = r.beats;
    r.bpm = -1;
    r.signature_beats = 0;
    r.tempo_mode = "unavailable";
    if (b.size() < 2 || b[0] < 0) return;
    for (size_t i = 1; i < b.size(); ++i)
        if (!(b[i] > b[i - 1])) return;
    // Beats per bar: downbeats must sit on beats at a constant beat distance.
    int signature = 0;
    if (r.downbeats.size() >= 3) {
        std::vector<long> idx;
        for (double d : r.downbeats) {
            long found = -1;
            for (size_t i = 0; i < b.size(); ++i)
                if (std::fabs(b[i] - d) <= 1e-6) { found = static_cast<long>(i); break; }
            idx.push_back(found);
        }
        const bool all = std::all_of(idx.begin(), idx.end(), [](long v) { return v >= 0; });
        if (all) {
            const long n = idx[1] - idx[0];
            bool steady = n >= 1 && n <= 255;
            for (size_t i = 1; steady && i < idx.size(); ++i) steady = idx[i] - idx[i - 1] == n;
            if (steady) signature = static_cast<int>(n);
        }
    }
    // Least-squares grid fit: beat i ~ offset + period * i.
    const double nb = static_cast<double>(b.size());
    const double mid = (nb - 1) / 2;
    double mean = 0;
    for (double t : b) mean += t;
    mean /= nb;
    double num = 0, den = 0;
    for (size_t i = 0; i < b.size(); ++i) {
        num += (static_cast<double>(i) - mid) * (b[i] - mean);
        den += (static_cast<double>(i) - mid) * (static_cast<double>(i) - mid);
    }
    const double period = num / den, offset = mean - period * mid;
    double residual = 0;
    for (size_t i = 0; i < b.size(); ++i) residual = std::max(residual, std::fabs(b[i] - offset - period * static_cast<double>(i)));
    const bool constant = b.size() >= 5 && signature != 0 && residual <= 0.03;
    const bool variable = b.size() >= 5 && residual > 0.03;
    const double p = constant ? period : (b.back() - b.front()) / (nb - 1);
    const double tempo_us = std::nearbyint(p * 1e6);
    if (tempo_us < 1 || tempo_us > 0xffffff) return;
    r.bpm = std::round(60e6 / tempo_us * 1000) / 1000;
    r.signature_beats = signature;
    r.tempo_mode = constant ? "constant" : (variable ? "variable" : "average");
}

int extract_file(ke_runtime* rt, const std::string& model_dir, const std::string& input_wav,
                 const std::string& out_json, ke_progress_cb progress, void* user) {
    const auto t_start = std::chrono::steady_clock::now();
    int rc = report_progress(progress, user, 0.f, "decode");
    if (rc != KE_OK) return rc;
    Frontend fe;
    rc = load_frontend(model_dir + "/frontend.json", fe);
    if (rc != KE_OK) return rc;
    AudioBuffer buf;
    rc = read_wav(input_wav, buf);
    if (rc != KE_OK) return rc;
    if (buf.frames() == 0) return fail(KE_ERR_INVALID_ARG, "beat_this: %s is empty", input_wav.c_str());
    std::vector<float> mono = to_mono(buf);
    rc = report_progress(progress, user, 0.04f, "resample");
    if (rc != KE_OK) return rc;
    if (buf.sample_rate != kSampleRate) mono = resample(mono, buf.sample_rate, kSampleRate);
    if (mono.size() < static_cast<size_t>(fe.n_fft)) return fail(KE_ERR_INVALID_ARG, "beat_this: audio too short");

    Result result;
    const bool audible = std::any_of(mono.begin(), mono.end(), [](float v) { return std::fabs(v) >= 1e-7f; });
    if (audible) {
        rc = report_progress(progress, user, 0.08f, "spectrogram");
        if (rc != KE_OK) return rc;
        long frames = 0;
        const auto spect = log_mel(mono, fe, frames);

        rc = report_progress(progress, user, 0.2f, "load");
        if (rc != KE_OK) return rc;
        std::string err;
        auto session = OrtSession::create(rt, model_dir + "/beat-this-final0.onnx", &err);
        if (!session) return fail_str(KE_ERR_MODEL, "beat_this: " + err);

        std::vector<float> beat(static_cast<size_t>(frames), -1000.f), down(static_cast<size_t>(frames), -1000.f);
        const auto starts = chunk_starts(frames);
        std::vector<float> chunk;
        for (long ci = static_cast<long>(starts.size()) - 1; ci >= 0; --ci) {  // reverse: earlier chunks win
            const long start = starts[static_cast<size_t>(ci)];
            const long left = std::max(0L, -start);
            const long right = std::max(0L, std::min<long>(kBorder, start + kChunk - frames));
            const long from = std::max(0L, start), to = std::min<long>(start + kChunk, frames);
            const long len = to - from + left + right;
            chunk.assign(static_cast<size_t>(len) * 128, 0.f);
            std::copy(spect.begin() + from * 128, spect.begin() + to * 128, chunk.begin() + left * 128);
            std::vector<TensorView> in{tensor_f32("spectrogram", {1, len, 128}, chunk.data())};
            std::vector<TensorOut> outs;
            rc = session->run(in, {"beat", "downbeat"}, outs);
            if (rc != KE_OK) return rc;
            const float* pb = outs[0].f32();
            const float* pd = outs[1].f32();
            const long n = static_cast<long>(outs[0].count());
            for (long i = kBorder; i < n - kBorder; ++i) {
                const long k = start + i;
                if (k < 0 || k >= frames) continue;
                beat[static_cast<size_t>(k)] = pb[i];
                down[static_cast<size_t>(k)] = pd[i];
            }
            rc = report_progress(progress, user, 0.2f + 0.75f * float(starts.size() - ci) / float(starts.size()), "beats");
            if (rc != KE_OK) return rc;
        }
        postprocess(beat, down, result);
        estimate_tempo(result);
    }
    rc = report_progress(progress, user, 0.97f, "write");
    if (rc != KE_OK) return rc;
    write_json(out_json, result, rc);
    if (rc != KE_OK) return rc;
    const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count();
    KE_LOGI("beat_this: %zu beats, %zu downbeats, bpm %.2f (%s, %d/x) in %.2f s -> %s", result.beats.size(),
            result.downbeats.size(), result.bpm, result.tempo_mode.c_str(), result.signature_beats, secs, out_json.c_str());
    return report_progress(progress, user, 1.f, "done");
}

}  // namespace ke::beat_this
