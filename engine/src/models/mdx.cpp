// UVR MDX-Net separation. Port of audio-separator's MDXSeparator.demix()
// (audio_separator/separator/architectures/mdx_separator.py), which mirrors
// UVR's SeperateMDX.demix(). Every numerical step follows that reference:
//
//   trim       = n_fft / 2
//   chunk_size = hop * (dim_t - 1)                 (dim_t = 2^dim_t_log2)
//   gen_size   = chunk_size - 2 * trim
//   pad        = gen_size + trim - (n % gen_size)
//   mixture    = [zeros(trim), mix, zeros(pad)]
//   step       = int((1 - overlap) * chunk_size)
//   for start in 0, step, 2*step, ... < len(mixture):
//       end    = min(start + chunk_size, len(mixture))
//       window = np.hanning(end - start)          (symmetric Hann)
//       part   = mixture[start:end] zero padded to chunk_size
//       spec   = torch.stft(part, n_fft, hop, hann_window(periodic), center=True)[:dim_f]
//       spec[:3 bins] = 0
//       out    = model([L.re, L.im, R.re, R.im])  -> zero-pad bins to n_fft/2+1
//       wave   = torch.istft(out, ...)            (chunk_size samples)
//       result[start:end] += wave[:end-start] * window ; divider[start:end] += window
//   primary   = (result / divider)[trim : trim + n]
//   secondary = mix - primary * compensate
#include "models/mdx.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstring>
#include <vector>

#include "nlohmann/json.hpp"

#include "core/error.h"
#include "core/ort_runtime.h"
#include "core/resample.h"
#include "core/wav.h"
#include "dsp/stft.h"

namespace ke::mdx {

namespace {

constexpr int kModelRate = 44100;
constexpr double kPi = 3.14159265358979323846;

using Clock = std::chrono::steady_clock;
double ms_since(Clock::time_point t0) {
    return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

// Reads a numeric field (int or float) if present; returns false on a type error.
template <typename T>
bool get_number(const nlohmann::json& j, const char* key, T& out) {
    auto it = j.find(key);
    if (it == j.end() || it->is_null()) return true;
    if (!it->is_number()) return false;
    out = it->get<T>();
    return true;
}

// Verifies the model's single float input is [*, 4, dim_f, dim_t] (fixed dims only).
int check_model_io(ke_runtime* rt, OrtSession& session, const Params& p, int dim_t) {
    if (session.input_names().size() != 1) {
        return fail(KE_ERR_MODEL, "MDX model must have exactly one input, has %zu", session.input_names().size());
    }
    const OrtApi* api = rt->api;
    OrtTypeInfo* ti = nullptr;
    if (api->SessionGetInputTypeInfo(session.raw(), 0, &ti) != nullptr || !ti) return KE_OK;  // can't check; ORT will
    const OrtTensorTypeAndShapeInfo* tsi = nullptr;
    std::vector<int64_t> shape;
    ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    if (api->CastTypeInfoToTensorInfo(ti, &tsi) == nullptr && tsi) {
        size_t dims = 0;
        (void)api->GetDimensionsCount(tsi, &dims);
        shape.resize(dims);
        (void)api->GetDimensions(tsi, shape.data(), dims);
        (void)api->GetTensorElementType(tsi, &type);
    }
    api->ReleaseTypeInfo(ti);
    if (type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) return fail(KE_ERR_MODEL, "MDX model input is not float32");
    if (shape.size() != 4) return fail(KE_ERR_MODEL, "MDX model input must be 4-D, is %zu-D", shape.size());
    const int64_t want[4] = {-1, 4, p.dim_f, dim_t};
    for (int i = 1; i < 4; ++i) {
        if (shape[i] > 0 && shape[i] != want[i]) {
            return fail(KE_ERR_MODEL, "MDX model input dim %d is %lld, params say %lld (check n_fft/dim_f/dim_t_log2)",
                        i, static_cast<long long>(shape[i]), static_cast<long long>(want[i]));
        }
    }
    return KE_OK;
}

}  // namespace

int parse_params(const std::string& json, Params& out) {
    Params p;
    try {
        const nlohmann::json j = json.empty() ? nlohmann::json::object() : nlohmann::json::parse(json);
        if (!j.is_object()) return fail(KE_ERR_INVALID_ARG, "mdx params must be a JSON object");
        bool ok = true;
        ok = ok && get_number(j, "n_fft", p.n_fft);
        ok = ok && get_number(j, "hop_length", p.hop_length);
        ok = ok && get_number(j, "dim_f", p.dim_f);
        ok = ok && get_number(j, "dim_t_log2", p.dim_t_log2);
        ok = ok && get_number(j, "compensate", p.compensate);
        ok = ok && get_number(j, "overlap", p.overlap);
        ok = ok && get_number(j, "batch_size", p.batch_size);
        if (!ok) return fail(KE_ERR_INVALID_ARG, "mdx params: numeric field has wrong type");
        if (auto it = j.find("primary_stem"); it != j.end() && !it->is_null()) {
            if (!it->is_string()) return fail(KE_ERR_INVALID_ARG, "mdx params: primary_stem must be a string");
            p.primary_stem = it->get<std::string>();
        }
    } catch (const std::exception& e) {
        return fail(KE_ERR_INVALID_ARG, "mdx params: invalid JSON: %s", e.what());
    }
    if (p.n_fft < 16 || (p.n_fft % 2) != 0) return fail(KE_ERR_INVALID_ARG, "mdx params: n_fft must be even and >= 16");
    if (p.hop_length <= 0 || p.hop_length > p.n_fft) return fail(KE_ERR_INVALID_ARG, "mdx params: hop_length out of range");
    if (p.dim_f <= 0 || p.dim_f > p.n_fft / 2 + 1) return fail(KE_ERR_INVALID_ARG, "mdx params: dim_f must be in [1, n_fft/2+1]");
    if (p.dim_t_log2 < 1 || p.dim_t_log2 > 16) return fail(KE_ERR_INVALID_ARG, "mdx params: dim_t_log2 must be in [1,16]");
    if (!(p.overlap >= 0.f) || p.overlap >= 1.f) return fail(KE_ERR_INVALID_ARG, "mdx params: overlap must be in [0,1)");
    if (!(p.compensate > 0.f) || !std::isfinite(p.compensate)) return fail(KE_ERR_INVALID_ARG, "mdx params: compensate must be > 0");
    if (p.batch_size < 1 || p.batch_size > 64) return fail(KE_ERR_INVALID_ARG, "mdx params: batch_size must be in [1,64]");
    const int dim_t = 1 << p.dim_t_log2;
    if (static_cast<long long>(p.hop_length) * (dim_t - 1) <= p.n_fft) {
        return fail(KE_ERR_INVALID_ARG, "mdx params: chunk (hop*(dim_t-1)) must exceed n_fft");
    }
    out = p;
    return KE_OK;
}

int separate(ke_runtime* rt, const std::string& model_path, const std::string& params_json,
             const std::string& input_wav, const std::string& primary_out_wav,
             const std::string& secondary_out_wav, ke_progress_cb progress, void* user) {
    if (!rt) return fail(KE_ERR_INVALID_ARG, "mdx::separate: runtime is null");
    if (primary_out_wav.empty() && secondary_out_wav.empty()) {
        return fail(KE_ERR_INVALID_ARG, "mdx::separate: no output path given");
    }
    Params p;
    int rc = parse_params(params_json, p);
    if (rc != KE_OK) return rc;

    const auto t_start = Clock::now();

    // ---- 1. decode, stereo, 44.1 kHz --------------------------------------------
    AudioBuffer in;
    rc = read_wav(input_wav, in);
    if (rc != KE_OK) return rc;
    if (in.frames() == 0) return fail(KE_ERR_INVALID_ARG, "mdx::separate: %s is empty", input_wav.c_str());
    AudioBuffer mix = with_channels(in, 2);
    in.planes.clear();
    if (mix.sample_rate != kModelRate) {
        const auto t0 = Clock::now();
        for (auto& plane : mix.planes) plane = resample(plane, mix.sample_rate, kModelRate);
        KE_LOGI("mdx: resampled %d -> %d Hz in %.0f ms", mix.sample_rate, kModelRate, ms_since(t0));
        mix.sample_rate = kModelRate;
    }
    const size_t n = mix.frames();
    KE_LOGI("mdx: input %s: %.1f s stereo @ %d Hz, decoded in %.0f ms", input_wav.c_str(),
            mix.duration(), mix.sample_rate, ms_since(t_start));
    rc = report_progress(progress, user, 0.f, "decode");
    if (rc != KE_OK) return rc;

    // ---- 2. session ---------------------------------------------------------------
    const auto t_sess = Clock::now();
    std::string err;
    auto session = OrtSession::create(rt, model_path, &err);
    if (!session) return fail_str(KE_ERR_MODEL, err.empty() ? std::string("cannot create MDX session") : err);
    const int dim_t = 1 << p.dim_t_log2;
    rc = check_model_io(rt, *session, p, dim_t);
    if (rc != KE_OK) return rc;
    KE_LOGI("mdx: session %s on %s in %.0f ms (n_fft=%d hop=%d dim_f=%d dim_t=%d overlap=%.3f compensate=%.4f stem=%s batch=%d)",
            model_path.c_str(), ep_name(rt->active_ep), ms_since(t_sess), p.n_fft, p.hop_length, p.dim_f, dim_t,
            p.overlap, p.compensate, p.primary_stem.c_str(), p.batch_size);

    // ---- 3. geometry (see header comment) -----------------------------------------
    const size_t trim = static_cast<size_t>(p.n_fft / 2);
    const size_t chunk = static_cast<size_t>(p.hop_length) * static_cast<size_t>(dim_t - 1);
    const size_t gen = chunk - 2 * trim;
    const size_t pad = gen + trim - (n % gen);
    const size_t total = trim + n + pad;           // length of the padded mixture
    size_t step = static_cast<size_t>(static_cast<double>(1.0f - p.overlap) * static_cast<double>(chunk));
    if (step == 0) step = 1;
    const size_t num_chunks = (total + step - 1) / step;
    const bool use_window = p.overlap != 0.f;

    // Padded mixture (planar), accumulators and divider.
    std::vector<std::vector<float>> mixture(2, std::vector<float>(total, 0.f));
    for (int c = 0; c < 2; ++c) std::memcpy(mixture[c].data() + trim, mix.planes[c].data(), n * sizeof(float));
    std::vector<std::vector<float>> result(2, std::vector<float>(total, 0.f));
    std::vector<float> divider(total, 0.f);

    dsp::Stft stft(p.n_fft, p.hop_length, dsp::Window::HannPeriodic, true);
    const size_t bins = static_cast<size_t>(stft.n_bins());
    const size_t frames = stft.num_frames(chunk);
    if (frames != static_cast<size_t>(dim_t)) {
        return fail(KE_ERR_INTERNAL, "mdx: chunk of %zu samples gives %zu frames, expected %d", chunk, frames, dim_t);
    }
    const size_t plane = static_cast<size_t>(p.dim_f) * dim_t;    // floats per [dim_f, dim_t] plane
    const size_t per_item = 4 * plane;                              // floats per batch item

    // Per-batch work buffers.
    const int B = std::min<int>(p.batch_size, static_cast<int>(num_chunks));
    std::vector<float> input(static_cast<size_t>(B) * per_item);
    std::vector<size_t> starts;
    starts.reserve(B);
    std::vector<float> part(chunk);
    std::vector<std::complex<float>> spec;
    std::vector<std::complex<float>> spec_out(frames * bins);
    std::vector<float> wave;
    std::vector<float> window(chunk);
    std::vector<TensorOut> outputs;
    const std::string input_name = session->input_names()[0];

    double ms_stft = 0, ms_model = 0, ms_istft = 0;
    size_t done = 0;

    // Runs the model on the collected batch and overlap-adds the results.
    auto flush = [&]() -> int {
        if (starts.empty()) return KE_OK;
        const int b = static_cast<int>(starts.size());
        const auto t0 = Clock::now();
        const std::vector<int64_t> shape{b, 4, p.dim_f, dim_t};
        rc = session->run({tensor_f32(input_name.c_str(), shape, input.data())}, {}, outputs);
        if (rc != KE_OK) return rc;
        ms_model += ms_since(t0);
        if (outputs.empty() || outputs[0].type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
            outputs[0].count() != static_cast<size_t>(b) * per_item) {
            return fail(KE_ERR_MODEL, "mdx: unexpected model output (%zu floats, expected %zu)",
                        outputs.empty() ? size_t(0) : outputs[0].count(), static_cast<size_t>(b) * per_item);
        }
        const auto t1 = Clock::now();
        const float* out = outputs[0].f32();
        for (int i = 0; i < b; ++i) {
            const size_t start = starts[i];
            const size_t end = std::min(start + chunk, total);
            const size_t actual = end - start;
            if (use_window) {   // np.hanning(actual): symmetric Hann
                if (actual == 1) window[0] = 1.f;
                else for (size_t k = 0; k < actual; ++k)
                    window[k] = static_cast<float>(0.5 - 0.5 * std::cos(2.0 * kPi * static_cast<double>(k) / static_cast<double>(actual - 1)));
            }
            for (int c = 0; c < 2; ++c) {
                const float* re = out + static_cast<size_t>(i) * per_item + static_cast<size_t>(2 * c) * plane;
                const float* im = re + plane;
                // [dim_f, dim_t] -> frames x bins, zero above dim_f.
                for (size_t f = 0; f < frames; ++f) {
                    std::complex<float>* row = spec_out.data() + f * bins;
                    for (size_t k = 0; k < static_cast<size_t>(p.dim_f); ++k) row[k] = {re[k * dim_t + f], im[k * dim_t + f]};
                    for (size_t k = static_cast<size_t>(p.dim_f); k < bins; ++k) row[k] = {0.f, 0.f};
                }
                stft.inverse(spec_out.data(), frames, chunk, wave);
                float* acc = result[c].data() + start;
                if (use_window) for (size_t k = 0; k < actual; ++k) acc[k] += wave[k] * window[k];
                else for (size_t k = 0; k < actual; ++k) acc[k] += wave[k];
            }
            if (use_window) for (size_t k = 0; k < actual; ++k) divider[start + k] += window[k];
            else for (size_t k = 0; k < actual; ++k) divider[start + k] += 1.f;
        }
        ms_istft += ms_since(t1);
        done += starts.size();
        starts.clear();
        return report_progress(progress, user, static_cast<float>(done) / static_cast<float>(num_chunks), "model");
    };

    rc = report_progress(progress, user, 0.f, "model");
    if (rc != KE_OK) return rc;
    for (size_t start = 0; start < total; start += step) {
        const size_t end = std::min(start + chunk, total);
        const auto t0 = Clock::now();
        float* item = input.data() + starts.size() * per_item;
        for (int c = 0; c < 2; ++c) {
            std::memcpy(part.data(), mixture[c].data() + start, (end - start) * sizeof(float));
            std::fill(part.begin() + (end - start), part.end(), 0.f);
            stft.forward(part.data(), chunk, spec);          // frames x bins
            float* re = item + static_cast<size_t>(2 * c) * plane;
            float* im = re + plane;
            for (size_t f = 0; f < frames; ++f) {
                const std::complex<float>* row = spec.data() + f * bins;
                for (size_t k = 0; k < static_cast<size_t>(p.dim_f); ++k) {
                    re[k * dim_t + f] = row[k].real();
                    im[k * dim_t + f] = row[k].imag();
                }
            }
            // spek[:, :, :3, :] *= 0
            for (size_t k = 0; k < 3 && k < static_cast<size_t>(p.dim_f); ++k) {
                std::fill(re + k * dim_t, re + (k + 1) * dim_t, 0.f);
                std::fill(im + k * dim_t, im + (k + 1) * dim_t, 0.f);
            }
        }
        ms_stft += ms_since(t0);
        starts.push_back(start);
        if (static_cast<int>(starts.size()) == B) {
            rc = flush();
            if (rc != KE_OK) return rc;
        }
    }
    rc = flush();
    if (rc != KE_OK) return rc;
    mixture.clear();
    KE_LOGI("mdx: %zu chunks (chunk=%zu step=%zu): stft %.0f ms, model %.0f ms (%.0f ms/chunk), istft %.0f ms",
            num_chunks, chunk, step, ms_stft, ms_model, ms_model / static_cast<double>(num_chunks), ms_istft);

    // ---- 4. normalise by the window sum, cut the trim, write stems -------------------
    AudioBuffer primary;
    primary.sample_rate = kModelRate;
    primary.channels = 2;
    primary.planes.assign(2, std::vector<float>(n, 0.f));
    for (int c = 0; c < 2; ++c) {
        for (size_t i = 0; i < n; ++i) {
            const float d = divider[trim + i];
            primary.planes[c][i] = d > 0.f ? result[c][trim + i] / d : 0.f;
        }
    }
    result.clear();
    divider.clear();

    if (!primary_out_wav.empty()) {
        rc = write_wav_f32(primary_out_wav, primary);
        if (rc != KE_OK) return rc;
    }
    if (!secondary_out_wav.empty()) {
        AudioBuffer secondary;
        secondary.sample_rate = kModelRate;
        secondary.channels = 2;
        secondary.planes.assign(2, std::vector<float>(n, 0.f));
        for (int c = 0; c < 2; ++c) {
            const float* m = mix.planes[c].data();
            const float* pr = primary.planes[c].data();
            float* s = secondary.planes[c].data();
            for (size_t i = 0; i < n; ++i) s[i] = m[i] - pr[i] * p.compensate;
        }
        rc = write_wav_f32(secondary_out_wav, secondary);
        if (rc != KE_OK) return rc;
    }
    KE_LOGI("mdx: done in %.0f ms (%.2fx realtime)", ms_since(t_start), mix.duration() * 1000.0 / ms_since(t_start));
    return report_progress(progress, user, 1.f, "model");
}

}  // namespace ke::mdx
