// SwiftF0 pitch estimator — replicates swift-f0 0.3.0 (pip, MIT) exactly:
//
//   * mono float32 @ 16 kHz, model input audio[1,N], fmin/fmax rank-0 f32
//   * frames = max(1, N // 256); frame i is stamped i * 0.016 s (no offset)
//   * fmin/fmax are clamped into [46.875, 2093.75] and must span >= one of the
//     model's 95 log-spaced bins
//   * frames whose own 256-sample hop peaks below 1e-3 get confidence 0
//     (digital silence makes the model answer with random voiced frames)
//   * long input is processed in 1875-frame (30 s) windows with 11 frames of
//     left context and 10 frames of right lookahead; the model's receptive
//     field is 2815 samples each way, so this reproduces the single-pass
//     result bit for bit (checked numerically against the ONNX model).
#include "models/swiftf0.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>

#include "core/error.h"
#include "core/ort_runtime.h"
#include "core/resample.h"
#include "core/wav.h"

namespace ke::swiftf0 {

namespace {

constexpr float kSilencePeak = 1e-3f;

}  // namespace

Model::~Model() = default;

std::unique_ptr<Model> Model::load(ke_runtime* rt, const std::string& model_path, std::string* error) {
    if (!rt) {
        if (error) *error = "swiftf0: runtime is null";
        fail(KE_ERR_INVALID_ARG, "swiftf0: runtime is null");
        return nullptr;
    }
    std::string err;
    auto session = OrtSession::create(rt, model_path, &err);
    if (!session) {
        if (error) *error = err;
        return nullptr;
    }
    if (!session->has_input("audio") || !session->has_input("fmin") || !session->has_input("fmax")) {
        std::string msg = "swiftf0: model at " + model_path + " does not have inputs audio/fmin/fmax";
        if (error) *error = msg;
        fail_str(KE_ERR_MODEL, msg);
        return nullptr;
    }
    std::unique_ptr<Model> m(new Model());
    m->session_ = std::move(session);
    return m;
}

void clamp_range(float& fmin, float& fmax) {
    if (!(fmin > 0.f) || std::isnan(fmin)) fmin = kFminDefault;
    if (!(fmax > 0.f) || std::isnan(fmax)) fmax = kFmaxDefault;
    fmin = std::max(kFminDefault, fmin);
    fmax = std::min(kFmaxDefault, fmax);
    if (!(fmin < fmax)) { fmin = kFminDefault; fmax = kFmaxDefault; }
    if (fmax < fmin * kBinRatio) fmax = std::min(kFmaxDefault, fmin * kBinRatio);
}

int Model::run_window(const float* audio16k, size_t n, float fmin, float fmax,
                      std::vector<float>& f0, std::vector<float>& confidence) {
    std::vector<TensorView> inputs;
    inputs.push_back(tensor_f32("audio", {1, static_cast<int64_t>(n)}, audio16k));
    inputs.push_back(tensor_f32_scalar("fmin", &fmin));
    inputs.push_back(tensor_f32_scalar("fmax", &fmax));
    std::vector<TensorOut> outs;
    int rc = session_->run(inputs, {"pitch", "confidence"}, outs);
    if (rc != KE_OK) return rc;
    if (outs.size() != 2) return fail(KE_ERR_MODEL, "swiftf0: expected 2 outputs, got %zu", outs.size());
    const TensorOut& pitch = outs[0];
    const TensorOut& conf = outs[1];
    const size_t frames = conf.count();
    if (pitch.count() != frames) return fail(KE_ERR_MODEL, "swiftf0: pitch/confidence frame mismatch");
    f0.resize(frames);
    confidence.resize(frames);
    if (pitch.type == ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE) {
        const double* p = pitch.f64();
        for (size_t i = 0; i < frames; ++i) f0[i] = static_cast<float>(p[i]);
    } else if (pitch.type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        const float* p = pitch.f32();
        for (size_t i = 0; i < frames; ++i) f0[i] = p[i];
    } else {
        return fail(KE_ERR_MODEL, "swiftf0: unexpected pitch dtype %d", static_cast<int>(pitch.type));
    }
    if (conf.type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
        return fail(KE_ERR_MODEL, "swiftf0: unexpected confidence dtype %d", static_cast<int>(conf.type));
    const float* c = conf.f32();
    for (size_t i = 0; i < frames; ++i) confidence[i] = c[i];
    // Silence gate (swift-f0 _run): hop i = audio[i*256, (i+1)*256); a stream shorter
    // than one hop uses all of its samples.
    for (size_t i = 0; i < frames; ++i) {
        size_t a = i * kHop, b = std::min(n, (i + 1) * kHop);
        if (n < static_cast<size_t>(kHop)) { a = 0; b = n; }
        float peak = 0.f;
        for (size_t k = a; k < b; ++k) peak = std::max(peak, std::fabs(audio16k[k]));
        if (peak < kSilencePeak) confidence[i] = 0.f;
    }
    return KE_OK;
}

int Model::run(const float* audio16k, size_t n, float fmin, float fmax,
               std::vector<float>& f0, std::vector<float>& confidence, ke_progress_cb progress, void* user) {
    f0.clear();
    confidence.clear();
    if (!audio16k || n == 0) return fail(KE_ERR_INVALID_ARG, "swiftf0: empty audio");
    clamp_range(fmin, fmax);
    const size_t n_frames = std::max<size_t>(1, n / kHop);
    std::vector<float> wf0, wconf;
    f0.reserve(n_frames);
    confidence.reserve(n_frames);
    for (size_t start = 0; start < n_frames; start += kWindowFrames) {
        const size_t end = std::min(start + kWindowFrames, n_frames);
        const size_t left = start >= kLeftFrames ? start - kLeftFrames : 0;
        const size_t s0 = left * kHop;
        const size_t s1 = end < n_frames ? std::min(n, (end + kLookaheadFrames) * kHop) : n;
        int rc = run_window(audio16k + s0, s1 - s0, fmin, fmax, wf0, wconf);
        if (rc != KE_OK) return rc;
        const size_t off = start - left;
        if (wf0.size() < off + (end - start))
            return fail(KE_ERR_MODEL, "swiftf0: model returned %zu frames, expected >= %zu", wf0.size(), off + (end - start));
        f0.insert(f0.end(), wf0.begin() + off, wf0.begin() + off + (end - start));
        confidence.insert(confidence.end(), wconf.begin() + off, wconf.begin() + off + (end - start));
        rc = report_progress(progress, user, 0.2f + 0.75f * float(end) / float(n_frames), "model");
        if (rc != KE_OK) return rc;
    }
    return KE_OK;
}

int Model::run(const float* audio16k, size_t n, float fmin, float fmax,
               std::vector<float>& f0, std::vector<float>& confidence) {
    return run(audio16k, n, fmin, fmax, f0, confidence, nullptr, nullptr);
}

float loudness_db(const float* audio16k, size_t n, size_t frame) {
    // swift-f0: RMS over the 512 samples centred on the frame (previous hop + own hop).
    double power = 0.0;
    const size_t a = frame >= 1 ? (frame - 1) * kHop : 0;
    const size_t b = std::min(n, (frame + 1) * kHop);
    for (size_t k = a; k < b; ++k) power += double(audio16k[k]) * audio16k[k];
    const double rms = std::sqrt(power / 512.0);
    return static_cast<float>(20.0 * std::log10(std::max(rms, 1e-7)));
}

int extract_file(ke_runtime* rt, const std::string& model_path, const std::string& input_wav,
                 float fmin, float fmax, const std::string& out_json, ke_progress_cb progress, void* user) {
    const auto t_start = std::chrono::steady_clock::now();
    int rc = report_progress(progress, user, 0.f, "decode");
    if (rc != KE_OK) return rc;
    AudioBuffer buf;
    rc = read_wav(input_wav, buf);
    if (rc != KE_OK) return rc;
    if (buf.frames() == 0) return fail(KE_ERR_INVALID_ARG, "swiftf0: %s is empty", input_wav.c_str());
    std::vector<float> mono = to_mono(buf);
    rc = report_progress(progress, user, 0.05f, "resample");
    if (rc != KE_OK) return rc;
    if (buf.sample_rate != kSampleRate) mono = resample(mono, buf.sample_rate, kSampleRate);
    if (mono.empty()) return fail(KE_ERR_INVALID_ARG, "swiftf0: audio too short to resample to 16 kHz");

    rc = report_progress(progress, user, 0.15f, "load");
    if (rc != KE_OK) return rc;
    std::string err;
    auto model = Model::load(rt, model_path, &err);
    if (!model) return fail_str(KE_ERR_MODEL, "swiftf0: " + err);

    clamp_range(fmin, fmax);
    std::vector<float> f0, conf;
    rc = model->run(mono.data(), mono.size(), fmin, fmax, f0, conf, progress, user);
    if (rc != KE_OK) return rc;

    rc = report_progress(progress, user, 0.96f, "write");
    if (rc != KE_OK) return rc;
    FILE* fp = std::fopen(out_json.c_str(), "wb");
    if (!fp) return fail(KE_ERR_IO, "cannot write %s", out_json.c_str());
    std::string s;
    s.reserve(f0.size() * 40 + 256);
    char tmp[64];
    std::snprintf(tmp, sizeof(tmp), "{\"hop\":%.6g,\"sample_rate\":%d,\"fmin\":%.6g,\"fmax\":%.6g,",
                  double(kHop) / kSampleRate, kSampleRate, double(fmin), double(fmax));
    s += tmp;
    s += "\"times\":[";
    for (size_t i = 0; i < f0.size(); ++i) {
        std::snprintf(tmp, sizeof(tmp), "%s%.6g", i ? "," : "", double(i) * kHop / kSampleRate);
        s += tmp;
    }
    s += "],\"f0\":[";
    for (size_t i = 0; i < f0.size(); ++i) {
        const float v = conf[i] >= kVoicedThreshold ? f0[i] : 0.f;
        std::snprintf(tmp, sizeof(tmp), "%s%.4f", i ? "," : "", double(v));
        s += tmp;
    }
    s += "],\"confidence\":[";
    for (size_t i = 0; i < conf.size(); ++i) {
        std::snprintf(tmp, sizeof(tmp), "%s%.5f", i ? "," : "", double(conf[i]));
        s += tmp;
    }
    s += "]}\n";
    const size_t written = std::fwrite(s.data(), 1, s.size(), fp);
    std::fclose(fp);
    if (written != s.size()) return fail(KE_ERR_IO, "short write to %s", out_json.c_str());
    const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count();
    KE_LOGI("swiftf0: %zu frames (%.1f s audio, %d Hz in) in %.2f s -> %s", f0.size(),
            double(mono.size()) / kSampleRate, buf.sample_rate, secs, out_json.c_str());
    return report_progress(progress, user, 1.f, "done");
}

}  // namespace ke::swiftf0
