// Whisper recognition. See whisper.h for the pipeline.
#include "whisper.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <complex>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>

#include "../core/error.h"
#include "../core/ort_runtime.h"
#include "../core/resample.h"
#include "../core/wav.h"
#include "nlohmann/json.hpp"
#include "pocketfft/pocketfft_hdronly.h"

namespace ke::whisper {

// ---------------------------------------------------------------------------
// Front end
// ---------------------------------------------------------------------------

namespace {

constexpr double kPi = 3.14159265358979323846;

double hz_to_mel(double f) {
    const double min_log_hz = 1000.0, min_log_mel = 15.0, logstep = 27.0 / std::log(6.4);
    return f < min_log_hz ? 3.0 * f / 200.0 : min_log_mel + std::log(f / min_log_hz) * logstep;
}

double mel_to_hz(double m) {
    const double min_log_hz = 1000.0, min_log_mel = 15.0, logstep = std::log(6.4) / 27.0;
    return m < min_log_mel ? 200.0 * m / 3.0 : min_log_hz * std::exp(logstep * (m - min_log_mel));
}

}  // namespace

std::vector<float> mel_filters() {
    const int bins = kNfft / 2 + 1;
    std::vector<double> fft_freqs(bins);
    for (int k = 0; k < bins; ++k) fft_freqs[k] = double(kSampleRate) / 2.0 * k / (bins - 1);
    const double mel_min = hz_to_mel(0.0), mel_max = hz_to_mel(kSampleRate / 2.0);
    std::vector<double> f(kMels + 2);
    for (int i = 0; i < kMels + 2; ++i) f[i] = mel_to_hz(mel_min + (mel_max - mel_min) * i / (kMels + 1));
    std::vector<float> out(static_cast<size_t>(kMels) * bins, 0.f);
    for (int m = 0; m < kMels; ++m) {
        const double enorm = 2.0 / (f[m + 2] - f[m]);
        for (int k = 0; k < bins; ++k) {
            const double down = (fft_freqs[k] - f[m]) / (f[m + 1] - f[m]);
            const double up = (f[m + 2] - fft_freqs[k]) / (f[m + 2] - f[m + 1]);
            out[static_cast<size_t>(m) * bins + k] = static_cast<float>(std::max(0.0, std::min(down, up)) * enorm);
        }
    }
    return out;
}

void log_mel(const float* samples, size_t n, const std::vector<float>& filters, std::vector<float>& out) {
    const int bins = kNfft / 2 + 1;
    const long len = kWindowSamples;  // zero padded to 30 s, as pad_or_trim
    auto x = [&](long i) -> double { return (i >= 0 && static_cast<size_t>(i) < n) ? samples[i] : 0.0; };
    std::vector<double> window(kNfft);
    for (int j = 0; j < kNfft; ++j) window[j] = 0.5 - 0.5 * std::cos(2.0 * kPi * j / kNfft);  // periodic Hann

    std::vector<double> buf(kNfft);
    std::vector<std::complex<double>> spec(bins);
    std::vector<double> power(bins);
    pocketfft::shape_t shape{static_cast<size_t>(kNfft)};
    pocketfft::stride_t sin{sizeof(double)}, sout{sizeof(std::complex<double>)};
    std::vector<double> logspec(static_cast<size_t>(kMels) * kWindowFrames);
    double peak = -std::numeric_limits<double>::infinity();
    // 3001 centred frames with reflect padding; the last one is dropped.
    for (int t = 0; t < kWindowFrames; ++t) {
        for (int j = 0; j < kNfft; ++j) {
            long i = static_cast<long>(t) * kHop + j - kNfft / 2;
            if (i < 0) i = -i;
            if (i >= len) i = 2 * len - 2 - i;
            buf[j] = x(i) * window[j];
        }
        pocketfft::r2c<double>(shape, sin, sout, 0, true, buf.data(), spec.data(), 1.0);
        for (int k = 0; k < bins; ++k) power[k] = std::norm(spec[k]);
        for (int m = 0; m < kMels; ++m) {
            const float* w = &filters[static_cast<size_t>(m) * bins];
            double acc = 0;
            for (int k = 0; k < bins; ++k) acc += w[k] * power[k];
            const double v = std::log10(std::max(acc, 1e-10));
            logspec[static_cast<size_t>(m) * kWindowFrames + t] = v;
            peak = std::max(peak, v);
        }
    }
    out.resize(logspec.size());
    for (size_t i = 0; i < logspec.size(); ++i) out[i] = static_cast<float>((std::max(logspec[i], peak - 8.0) + 4.0) / 4.0);
}

std::vector<uint8_t> voiced_frames(const std::vector<float>& audio, double range_db, int hold) {
    const size_t frames = audio.size() / kHop;
    std::vector<double> db(frames);
    for (size_t t = 0; t < frames; ++t) {
        double e = 0;
        for (int j = 0; j < kHop; ++j) e += double(audio[t * kHop + j]) * audio[t * kHop + j];
        db[t] = 10.0 * std::log10(e / kHop + 1e-12);
    }
    if (frames == 0) return {};
    std::vector<double> sorted(db);
    const size_t k95 = std::min(frames - 1, static_cast<size_t>(0.95 * double(frames)));
    std::nth_element(sorted.begin(), sorted.begin() + static_cast<long>(k95), sorted.end());
    const double thr = std::max(sorted[k95] - range_db, -70.0);
    std::vector<uint8_t> out(frames, 0);
    long last = -1000000;
    for (size_t t = 0; t < frames; ++t) {  // forward hold
        if (db[t] > thr) last = static_cast<long>(t);
        if (static_cast<long>(t) - last <= hold) out[t] = 1;
    }
    long next = 1000000000;
    for (long t = static_cast<long>(frames) - 1; t >= 0; --t) {  // backward hold
        if (db[static_cast<size_t>(t)] > thr) next = t;
        if (next - t <= hold) out[static_cast<size_t>(t)] = 1;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Decoder with KV cache. Raw ORT values, so the cache stays inside ORT and
// the cross-attention cache is computed once per window.
// ---------------------------------------------------------------------------

namespace {

struct Tokens {
    int64_t eot = 50257, sot = 50258, sot_prev = 50362, no_speech = 50363, no_timestamps = 50364, ts_begin = 50365;
    int max_initial_ts = 50;
    std::vector<int64_t> suppress, begin_suppress;
};

int load_tokens(const std::string& path, Tokens& t) {
    std::ifstream in(path);
    if (!in) return fail(KE_ERR_MODEL, "whisper: cannot open %s", path.c_str());
    try {
        nlohmann::json j;
        in >> j;
        t.eot = j.at("eos_token_id").get<int64_t>();
        t.sot = j.at("decoder_start_token_id").get<int64_t>();
        t.no_timestamps = j.at("no_timestamps_token_id").get<int64_t>();
        t.ts_begin = t.no_timestamps + 1;
        t.no_speech = t.no_timestamps - 1;  // <|nospeech|> precedes <|notimestamps|>
        t.sot_prev = j.value("prev_sot_token_id", t.no_speech - 1);
        t.max_initial_ts = j.value("max_initial_timestamp_index", 50);
        t.suppress = j.value("suppress_tokens", std::vector<int64_t>{});
        t.begin_suppress = j.value("begin_suppress_tokens", std::vector<int64_t>{});
    } catch (const std::exception& e) {
        return fail(KE_ERR_MODEL, "whisper: bad generation_config.json: %s", e.what());
    }
    return KE_OK;
}

std::string ort_msg(const OrtApi* api, OrtStatus* st) {
    std::string s = api->GetErrorMessage(st);
    api->ReleaseStatus(st);
    return s;
}

class Decoder {
public:
    Decoder(ke_runtime* rt, const OrtSession& s) : api_(rt->api), sess_(s.raw()), session_(s) {}
    ~Decoder() {
        reset();
        if (mem_) api_->ReleaseMemoryInfo(mem_);
    }
    Decoder(const Decoder&) = delete;
    Decoder& operator=(const Decoder&) = delete;

    int init() {
        OrtStatus* st = api_->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem_);
        if (st) return fail(KE_ERR_ORT, "whisper: %s", ort_msg(api_, st).c_str());
        const auto& inputs = session_.input_names();
        for (const auto& n : inputs)
            if (n.rfind("past_key_values.", 0) == 0 && n.find(".decoder.key") != std::string::npos) ++layers_;
        if (layers_ == 0 || !session_.has_input("use_cache_branch")) return fail(KE_ERR_MODEL, "whisper: decoder_model_merged expected");
        // Heads and head size from past_key_values.0.decoder.key [b, heads, seq, dim].
        for (size_t i = 0; i < inputs.size(); ++i) {
            if (inputs[i] != "past_key_values.0.decoder.key") continue;
            OrtTypeInfo* ti = nullptr;
            if (OrtStatus* e = api_->SessionGetInputTypeInfo(sess_, i, &ti)) return fail(KE_ERR_ORT, "whisper: %s", ort_msg(api_, e).c_str());
            const OrtTensorTypeAndShapeInfo* tsi = nullptr;
            size_t dims = 0;
            int64_t d[4] = {0, 0, 0, 0};
            OrtStatus* e = api_->CastTypeInfoToTensorInfo(ti, &tsi);
            if (!e) e = api_->GetDimensionsCount(tsi, &dims);
            if (!e && dims == 4) e = api_->GetDimensions(tsi, d, 4);
            api_->ReleaseTypeInfo(ti);
            if (e) return fail(KE_ERR_ORT, "whisper: %s", ort_msg(api_, e).c_str());
            heads_ = d[1];
            head_dim_ = d[3];
        }
        if (heads_ <= 0 || head_dim_ <= 0) return fail(KE_ERR_MODEL, "whisper: cannot read the decoder's cache shape");
        for (int l = 0; l < layers_; ++l)
            for (const char* part : {"decoder.key", "decoder.value", "encoder.key", "encoder.value"}) {
                past_names_.push_back("past_key_values." + std::to_string(l) + "." + part);
                present_names_.push_back("present." + std::to_string(l) + "." + part);
            }
        return KE_OK;
    }

    // Starts a window on encoder output `enc` ([1, enc_len, d_model], kept
    // alive by the caller): runs `prefix`; `logits` gets every position.
    int start(const float* enc, int64_t enc_len, int64_t d_model, const std::vector<int64_t>& prefix,
              std::vector<float>& logits, int64_t& vocab) {
        reset();
        enc_ = enc;
        enc_shape_ = {1, enc_len, d_model};
        std::vector<OrtValue*> owned;
        std::vector<OrtValue*> inputs;
        std::vector<const char*> names;
        int rc = make_common(prefix, false, owned, inputs, names);
        if (rc != KE_OK) return rc;
        static float dummy = 0.f;
        const int64_t empty_shape[4] = {1, heads_, 0, head_dim_};
        for (const auto& n : past_names_) {
            OrtValue* v = nullptr;
            OrtStatus* st = api_->CreateTensorWithDataAsOrtValue(mem_, &dummy, 0, empty_shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &v);
            if (st) {
                release(owned);
                return fail(KE_ERR_ORT, "whisper: %s", ort_msg(api_, st).c_str());
            }
            owned.push_back(v);
            inputs.push_back(v);
            names.push_back(n.c_str());
        }
        std::vector<const char*> out_names{"logits"};
        for (const auto& n : present_names_) out_names.push_back(n.c_str());
        std::vector<OrtValue*> outs(out_names.size(), nullptr);
        OrtStatus* st = api_->Run(sess_, nullptr, names.data(), inputs.data(), inputs.size(), out_names.data(), out_names.size(), outs.data());
        release(owned);
        if (st) return fail(KE_ERR_ORT, "whisper decoder: %s", ort_msg(api_, st).c_str());
        rc = read_logits(outs[0], logits, vocab);
        api_->ReleaseValue(outs[0]);
        for (int l = 0; l < layers_; ++l) {
            self_.push_back(outs[1 + l * 4]);
            self_.push_back(outs[2 + l * 4]);
            cross_.push_back(outs[3 + l * 4]);
            cross_.push_back(outs[4 + l * 4]);
        }
        return rc;
    }

    // Feeds one more token; `logits` gets that position (1 x vocab).
    int step(int64_t token, std::vector<float>& logits, int64_t& vocab) {
        std::vector<OrtValue*> owned;
        std::vector<OrtValue*> inputs;
        std::vector<const char*> names;
        int rc = make_common({token}, true, owned, inputs, names);
        if (rc != KE_OK) return rc;
        for (int l = 0; l < layers_; ++l) {
            const size_t b = static_cast<size_t>(l);
            names.push_back(past_names_[b * 4].c_str());
            inputs.push_back(self_[b * 2]);
            names.push_back(past_names_[b * 4 + 1].c_str());
            inputs.push_back(self_[b * 2 + 1]);
            names.push_back(past_names_[b * 4 + 2].c_str());
            inputs.push_back(cross_[b * 2]);
            names.push_back(past_names_[b * 4 + 3].c_str());
            inputs.push_back(cross_[b * 2 + 1]);
        }
        std::vector<const char*> out_names{"logits"};
        for (int l = 0; l < layers_; ++l) {
            out_names.push_back(present_names_[static_cast<size_t>(l) * 4].c_str());
            out_names.push_back(present_names_[static_cast<size_t>(l) * 4 + 1].c_str());
        }
        std::vector<OrtValue*> outs(out_names.size(), nullptr);
        OrtStatus* st = api_->Run(sess_, nullptr, names.data(), inputs.data(), inputs.size(), out_names.data(), out_names.size(), outs.data());
        release(owned);
        if (st) return fail(KE_ERR_ORT, "whisper decoder: %s", ort_msg(api_, st).c_str());
        rc = read_logits(outs[0], logits, vocab);
        api_->ReleaseValue(outs[0]);
        release(self_);
        for (size_t i = 1; i < outs.size(); ++i) self_.push_back(outs[i]);
        return rc;
    }

    void reset() {
        release(self_);
        release(cross_);
    }

private:
    int make_common(const std::vector<int64_t>& ids, bool use_cache, std::vector<OrtValue*>& owned,
                    std::vector<OrtValue*>& inputs, std::vector<const char*>& names) {
        ids_ = ids;
        use_cache_ = use_cache;
        const int64_t ids_shape[2] = {1, static_cast<int64_t>(ids_.size())};
        const int64_t one = 1;
        const size_t enc_n = static_cast<size_t>(enc_shape_[1] * enc_shape_[2]);
        OrtValue *v_ids = nullptr, *v_enc = nullptr, *v_cache = nullptr;
        OrtStatus* st = api_->CreateTensorWithDataAsOrtValue(mem_, ids_.data(), ids_.size() * sizeof(int64_t), ids_shape, 2,
                                                             ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &v_ids);
        if (!st)
            st = api_->CreateTensorWithDataAsOrtValue(mem_, const_cast<float*>(enc_), enc_n * sizeof(float), enc_shape_.data(), 3,
                                                      ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &v_enc);
        if (!st)
            st = api_->CreateTensorWithDataAsOrtValue(mem_, &use_cache_, sizeof(bool), &one, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL, &v_cache);
        for (OrtValue* v : {v_ids, v_enc, v_cache})
            if (v) owned.push_back(v);
        if (st) {
            release(owned);
            return fail(KE_ERR_ORT, "whisper: %s", ort_msg(api_, st).c_str());
        }
        inputs = {v_ids, v_enc, v_cache};
        names = {"input_ids", "encoder_hidden_states", "use_cache_branch"};
        return KE_OK;
    }

    int read_logits(OrtValue* v, std::vector<float>& logits, int64_t& vocab) {
        OrtTensorTypeAndShapeInfo* info = nullptr;
        OrtStatus* st = api_->GetTensorTypeAndShape(v, &info);
        if (st) return fail(KE_ERR_ORT, "whisper: %s", ort_msg(api_, st).c_str());
        int64_t d[3] = {0, 0, 0};
        st = api_->GetDimensions(info, d, 3);
        api_->ReleaseTensorTypeAndShapeInfo(info);
        if (st) return fail(KE_ERR_ORT, "whisper: %s", ort_msg(api_, st).c_str());
        float* p = nullptr;
        st = api_->GetTensorMutableData(v, reinterpret_cast<void**>(&p));
        if (st) return fail(KE_ERR_ORT, "whisper: %s", ort_msg(api_, st).c_str());
        vocab = d[2];
        logits.assign(p, p + d[1] * d[2]);
        return KE_OK;
    }

    void release(std::vector<OrtValue*>& v) {
        for (OrtValue* x : v)
            if (x) api_->ReleaseValue(x);
        v.clear();
    }

    const OrtApi* api_;
    ::OrtSession* sess_;
    const OrtSession& session_;
    OrtMemoryInfo* mem_ = nullptr;
    int layers_ = 0;
    int64_t heads_ = 0, head_dim_ = 0;
    std::vector<std::string> past_names_, present_names_;
    std::vector<OrtValue*> self_;   // per layer: decoder key, value
    std::vector<OrtValue*> cross_;  // per layer: encoder key, value
    const float* enc_ = nullptr;
    std::vector<int64_t> enc_shape_{1, 0, 0};
    std::vector<int64_t> ids_;
    bool use_cache_ = false;
};

// ---------------------------------------------------------------------------
// Greedy decoding with the reference logit filters
// ---------------------------------------------------------------------------

constexpr float kNegInf = -std::numeric_limits<float>::infinity();

void log_softmax(const float* x, int64_t n, std::vector<float>& out) {
    float mx = kNegInf;
    for (int64_t i = 0; i < n; ++i) mx = std::max(mx, x[i]);
    double sum = 0;
    for (int64_t i = 0; i < n; ++i) sum += std::exp(double(x[i]) - mx);
    const float lse = mx + static_cast<float>(std::log(sum));
    out.resize(static_cast<size_t>(n));
    for (int64_t i = 0; i < n; ++i) out[static_cast<size_t>(i)] = x[i] - lse;
}

struct WindowResult {
    std::vector<int64_t> tokens;  // sampled tokens, without the final <|endoftext|>
    double sum_logprob = 0;
    float no_speech = 0;
    bool looped = false;          // stopped on a repetition loop
};

// True when the tail of `seq` is a unit of <= 4 tokens repeated >= 8 times.
bool repetition_loop(const std::vector<int64_t>& seq) {
    for (size_t unit = 1; unit <= 4; ++unit) {
        const size_t need = unit * 8;
        if (seq.size() < need) continue;
        bool same = true;
        for (size_t i = seq.size() - need; i + unit < seq.size() && same; ++i) same = seq[i] == seq[i + unit];
        if (same) return true;
    }
    return false;
}

int decode_window(Decoder& dec, const Tokens& tk, const float* enc, int64_t enc_len, int64_t d_model,
                  const std::vector<int64_t>& prefix, size_t sot_index, int max_tokens, WindowResult& r) {
    std::vector<float> logits, logprobs;
    int64_t vocab = 0;
    int rc = dec.start(enc, enc_len, d_model, prefix, logits, vocab);
    if (rc != KE_OK) return rc;
    // No-speech probability at the <|startoftranscript|> position.
    log_softmax(&logits[sot_index * static_cast<size_t>(vocab)], vocab, logprobs);
    r.no_speech = std::exp(logprobs[static_cast<size_t>(tk.no_speech)]);
    std::vector<float> cur(logits.end() - vocab, logits.end());

    std::vector<char> suppressed(static_cast<size_t>(vocab), 0);
    for (int64_t t : tk.suppress)
        if (t >= 0 && t < vocab) suppressed[static_cast<size_t>(t)] = 1;
    for (int64_t t = tk.eot + 1; t < tk.ts_begin && t < vocab; ++t) suppressed[static_cast<size_t>(t)] = 1;  // special tokens

    auto& seq = r.tokens;
    for (int step = 0; step < max_tokens; ++step) {
        // --- filters ---
        for (int64_t i = 0; i < vocab; ++i)
            if (suppressed[static_cast<size_t>(i)]) cur[static_cast<size_t>(i)] = kNegInf;
        if (step == 0)
            for (int64_t t : tk.begin_suppress)
                if (t >= 0 && t < vocab) cur[static_cast<size_t>(t)] = kNegInf;
        auto is_ts = [&](int64_t t) { return t >= tk.ts_begin; };
        const bool last_ts = !seq.empty() && is_ts(seq.back());
        const bool penult_ts = seq.size() < 2 || is_ts(seq[seq.size() - 2]);
        if (last_ts) {
            if (penult_ts) {
                for (int64_t i = tk.ts_begin; i < vocab; ++i) cur[static_cast<size_t>(i)] = kNegInf;  // text next
            } else {
                for (int64_t i = 0; i < tk.eot; ++i) cur[static_cast<size_t>(i)] = kNegInf;  // timestamp or end next
            }
        }
        int64_t last_stamp = -1;
        for (auto it = seq.rbegin(); it != seq.rend(); ++it)
            if (is_ts(*it)) { last_stamp = *it; break; }
        if (last_stamp >= 0) {
            // Timestamps never go back; a closed segment's end may be reused
            // as the next start only right after it.
            const int64_t floor = (last_ts && !penult_ts) ? last_stamp : last_stamp + 1;
            for (int64_t i = tk.ts_begin; i < floor && i < vocab; ++i) cur[static_cast<size_t>(i)] = kNegInf;
        }
        if (step == 0) {
            for (int64_t i = 0; i < tk.ts_begin; ++i) cur[static_cast<size_t>(i)] = kNegInf;  // start with a timestamp
            for (int64_t i = tk.ts_begin + tk.max_initial_ts + 1; i < vocab; ++i) cur[static_cast<size_t>(i)] = kNegInf;
        }
        log_softmax(cur.data(), vocab, logprobs);
        {   // Timestamp when its total probability beats any single text token.
            float ts_max = kNegInf;
            double ts_sum = 0;
            for (int64_t i = tk.ts_begin; i < vocab; ++i) {
                ts_max = std::max(ts_max, logprobs[static_cast<size_t>(i)]);
            }
            if (ts_max > kNegInf) {
                for (int64_t i = tk.ts_begin; i < vocab; ++i) ts_sum += std::exp(double(logprobs[static_cast<size_t>(i)]) - ts_max);
                const double ts_lse = ts_max + std::log(ts_sum);
                float text_max = kNegInf;
                for (int64_t i = 0; i < tk.ts_begin; ++i) text_max = std::max(text_max, logprobs[static_cast<size_t>(i)]);
                if (ts_lse > text_max)
                    for (int64_t i = 0; i < tk.ts_begin; ++i) logprobs[static_cast<size_t>(i)] = kNegInf;
            }
        }
        // --- greedy pick ---
        int64_t best = 0;
        for (int64_t i = 1; i < vocab; ++i)
            if (logprobs[static_cast<size_t>(i)] > logprobs[static_cast<size_t>(best)]) best = i;
        if (logprobs[static_cast<size_t>(best)] == kNegInf) break;
        r.sum_logprob += logprobs[static_cast<size_t>(best)];
        if (best == tk.eot) break;
        seq.push_back(best);
        if (repetition_loop(seq)) {
            r.looped = true;
            break;
        }
        rc = dec.step(best, logits, vocab);
        if (rc != KE_OK) return rc;
        cur.assign(logits.begin(), logits.end());
    }
    return KE_OK;
}

}  // namespace

// ---------------------------------------------------------------------------
// Long-form recognition
// ---------------------------------------------------------------------------

int recognize_file(ke_runtime* rt, const std::string& model_dir, const std::string& input_wav,
                   const std::string& options_json, const std::string& out_json,
                   ke_progress_cb progress, void* user) {
    const auto t_start = std::chrono::steady_clock::now();
    int rc = report_progress(progress, user, 0.f, "decode");
    if (rc != KE_OK) return rc;

    int64_t language = 50260, task = 50360;
    std::vector<int64_t> style_prompt;
    bool condition = true;
    double no_speech_threshold = 0.6, logprob_threshold = -1.0;
    try {
        const auto o = nlohmann::json::parse(options_json.empty() ? "{}" : options_json);
        language = o.value("language_token", language);
        task = o.value("task_token", task);
        style_prompt = o.value("prompt_tokens", style_prompt);
        condition = o.value("condition_on_previous", condition);
        no_speech_threshold = o.value("no_speech_threshold", no_speech_threshold);
        logprob_threshold = o.value("logprob_threshold", logprob_threshold);
    } catch (const std::exception& e) {
        return fail(KE_ERR_INVALID_ARG, "whisper: bad options: %s", e.what());
    }

    Tokens tk;
    rc = load_tokens(model_dir + "/generation_config.json", tk);
    if (rc != KE_OK) return rc;

    AudioBuffer buf;
    rc = read_wav(input_wav, buf);
    if (rc != KE_OK) return rc;
    if (buf.frames() == 0) return fail(KE_ERR_INVALID_ARG, "whisper: %s is empty", input_wav.c_str());
    std::vector<float> audio = to_mono(buf);
    if (buf.sample_rate != kSampleRate) audio = resample(audio, buf.sample_rate, kSampleRate);
    const long total = static_cast<long>(audio.size() / kHop);  // mel frames
    const auto voiced = voiced_frames(audio);
    auto voiced_at = [&](long f) { return f >= 0 && f < static_cast<long>(voiced.size()) && voiced[static_cast<size_t>(f)]; };
    long v_first = -1;
    for (long f = 0; f < static_cast<long>(voiced.size()) && v_first < 0; ++f)
        if (voiced[static_cast<size_t>(f)]) v_first = f;

    nlohmann::json out;
    out["segments"] = nlohmann::json::array();
    out["duration"] = double(audio.size()) / kSampleRate;
    int windows = 0;

    if (v_first >= 0) {
        rc = report_progress(progress, user, 0.01f, "load");
        if (rc != KE_OK) return rc;
        std::string err;
        // float32 build, or the int8 one (onnx/*_quantized.onnx) when that is
        // what the directory holds.
        auto pick = [&](const std::string& base) {
            const std::string f32 = model_dir + "/onnx/" + base + ".onnx";
            return std::filesystem::exists(f32) ? f32 : model_dir + "/onnx/" + base + "_quantized.onnx";
        };
        auto encoder = OrtSession::create(rt, pick("encoder_model"), &err);
        if (!encoder) return fail_str(KE_ERR_MODEL, "whisper encoder: " + err);
        auto decoder_session = OrtSession::create(rt, pick("decoder_model_merged"), &err);
        if (!decoder_session) return fail_str(KE_ERR_MODEL, "whisper decoder: " + err);
        Decoder dec(rt, *decoder_session);
        rc = dec.init();
        if (rc != KE_OK) return rc;

        const auto filters = mel_filters();
        std::vector<float> mel;
        std::vector<int64_t> previous;  // tokens of the windows so far, timestamps included (as openai/whisper)
        long seek = std::max(0L, v_first - 50);
        const float load_part = 0.05f;
        while (seek < total) {
            // Skip a window without singing straight to the next voiced frame.
            long probe = seek;
            while (probe < total && probe < seek + kWindowFrames && !voiced_at(probe)) ++probe;
            if (probe >= seek + kWindowFrames || probe >= total) {
                long next = probe;
                while (next < total && !voiced_at(next)) ++next;
                if (next >= total) break;
                seek = std::max(seek, next - 50);
                continue;
            }
            rc = report_progress(progress, user, load_part + (1.f - load_part) * float(seek) / float(total), "recognize");
            if (rc != KE_OK) return rc;
            const long seg_frames = std::min<long>(kWindowFrames, total - seek);
            const size_t from = static_cast<size_t>(seek) * kHop;
            const size_t n = std::min<size_t>(static_cast<size_t>(seg_frames) * kHop, audio.size() - from);
            log_mel(audio.data() + from, n, filters, mel);

            std::vector<TensorOut> enc_out;
            rc = encoder->run({tensor_f32("input_features", {1, kMels, kWindowFrames}, mel.data())}, {"last_hidden_state"}, enc_out);
            if (rc != KE_OK) return rc;
            const int64_t enc_len = enc_out[0].shape.size() == 3 ? enc_out[0].shape[1] : 0;
            const int64_t d_model = enc_out[0].shape.size() == 3 ? enc_out[0].shape[2] : 0;
            if (enc_len <= 0 || d_model <= 0) return fail(KE_ERR_MODEL, "whisper: unexpected encoder output");

            // Previous text: the style prompt, then what was recognised so far
            // with its timestamps, so the model keeps writing timestamps.
            std::vector<int64_t> prompt = style_prompt;
            if (condition) prompt.insert(prompt.end(), previous.end() - static_cast<long>(std::min<size_t>(previous.size(), 180)), previous.end());
            if (prompt.size() > 223) prompt.erase(prompt.begin(), prompt.end() - 223);
            std::vector<int64_t> prefix;
            if (!prompt.empty()) {
                prefix.push_back(tk.sot_prev);
                prefix.insert(prefix.end(), prompt.begin(), prompt.end());
            }
            const size_t sot_index = prefix.size();
            prefix.insert(prefix.end(), {tk.sot, language, task});

            WindowResult wr;
            rc = decode_window(dec, tk, enc_out[0].f32(), enc_len, d_model, prefix, sot_index, 224, wr);
            if (rc != KE_OK) return rc;
            ++windows;
            const double offset = double(seek) / 100.0;
            const auto& toks = wr.tokens;
            const double avg_lp = wr.sum_logprob / double(toks.size() + 1);
            if (wr.no_speech > no_speech_threshold && avg_lp < logprob_threshold) {
                seek += seg_frames;  // silence or noise
                continue;
            }
            auto is_ts = [&](int64_t t) { return t >= tk.ts_begin; };
            auto ts_sec = [&](int64_t t) { return double(t - tk.ts_begin) * 0.02; };
            auto add_segment = [&](double start, double end, const std::vector<int64_t>& seg) {
                std::vector<int64_t> text;
                for (int64_t t : seg)
                    if (t < tk.eot) text.push_back(t);
                if (text.empty() || end <= start) return;
                // Text over (mostly) no singing is made up: skip it.
                const long f0 = static_cast<long>((offset + start) * 100.0), f1 = static_cast<long>((offset + end) * 100.0);
                long on = 0;
                for (long f = f0; f < f1; ++f) on += voiced_at(f) ? 1 : 0;
                if (f1 > f0 && double(on) / double(f1 - f0) < 0.3) return;
                nlohmann::json s;
                s["start"] = offset + start;
                s["end"] = offset + end;
                s["avg_logprob"] = avg_lp;
                s["tokens"] = text;
                out["segments"].push_back(s);
            };
            const bool single_end = toks.size() >= 2 && is_ts(toks.back()) && !is_ts(toks[toks.size() - 2]);
            std::vector<size_t> cuts;  // index of the second of two consecutive timestamps
            for (size_t i = 1; i < toks.size(); ++i)
                if (is_ts(toks[i]) && is_ts(toks[i - 1])) cuts.push_back(i);
            long advance = seg_frames;
            if (!cuts.empty() && !wr.looped) {
                if (single_end) cuts.push_back(toks.size());
                size_t last = 0;
                for (size_t c : cuts) {
                    if (c > last) {
                        std::vector<int64_t> seg(toks.begin() + static_cast<long>(last), toks.begin() + static_cast<long>(c));
                        if (seg.size() >= 2 && is_ts(seg.front()) && is_ts(seg.back()))
                            add_segment(ts_sec(seg.front()), ts_sec(seg.back()), seg);
                    }
                    last = c;
                }
                if (!single_end) {
                    const long pos = static_cast<long>(std::llround(ts_sec(toks[last - 1]) * 100.0));
                    if (pos > 0) advance = std::min<long>(pos, seg_frames);
                }
            } else {
                // One segment, from the first to the last timestamp.
                double start = 0, end = double(seg_frames) / 100.0;
                std::vector<double> stamps;
                for (int64_t t : toks)
                    if (is_ts(t)) stamps.push_back(ts_sec(t));
                if (!stamps.empty()) start = stamps.front();
                if (stamps.size() >= 2 && stamps.back() > start) end = stamps.back();
                std::vector<int64_t> text(toks.begin(), toks.end());
                if (wr.looped) {
                    // Keep one copy of the looping tail.
                    while (text.size() > 8 && repetition_loop(text)) text.pop_back();
                }
                add_segment(start, end, text);
            }
            if (!wr.looped) previous.insert(previous.end(), toks.begin(), toks.end());
            seek += std::max(advance, 1L);
        }
    }

    out["windows"] = windows;
    const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count();
    out["seconds"] = secs;
    std::ofstream f(out_json, std::ios::binary);
    if (!f) return fail(KE_ERR_IO, "whisper: cannot write %s", out_json.c_str());
    f << out.dump();
    if (!f) return fail(KE_ERR_IO, "whisper: cannot write %s", out_json.c_str());
    KE_LOGI("whisper: %d windows, %zu segments in %.1f s", windows, out["segments"].size(), secs);
    return report_progress(progress, user, 1.f, "recognize");
}

}  // namespace ke::whisper
