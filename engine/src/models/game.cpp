// GAME (openvpi) singing transcription: ONNX pipeline port of
// inference/me_infer.py + inference/callbacks.py (SaveCombinedFileCallback).
#include "models/game.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <sstream>

#include "core/error.h"
#include "core/ort_runtime.h"
#include "core/resample.h"
#include "core/wav.h"
#include "models/slicer.h"
#include "nlohmann/json.hpp"

namespace ke::game {

using nlohmann::json;

namespace {

std::string basename_of(const std::string& path) {
    std::string p = path;
    while (p.size() > 1 && (p.back() == '/' || p.back() == '\\')) p.pop_back();
    const size_t pos = p.find_last_of("/\\");
    return pos == std::string::npos ? p : p.substr(pos + 1);
}

std::string join_path(const std::string& dir, const char* file) {
    if (dir.empty()) return file;
    const char last = dir.back();
    if (last == '/' || last == '\\') return dir + file;
    return dir + "/" + file;
}

bool read_text_file(const std::string& path, std::string& out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

// Bool tensors are 1 byte per element in ORT; std::vector<bool> is a bitset,
// so we keep them as uint8_t and reinterpret.
const bool* as_bool(const std::vector<uint8_t>& v) { return reinterpret_cast<const bool*>(v.data()); }

int check_output(const TensorOut& o, const char* what, ONNXTensorElementDataType type, size_t rank) {
    if (o.type != type) return fail(KE_ERR_MODEL, "GAME: output %s has unexpected dtype %d", what, int(o.type));
    if (o.shape.size() != rank) return fail(KE_ERR_MODEL, "GAME: output %s has rank %zu, expected %zu", what, o.shape.size(), rank);
    return KE_OK;
}

// Mirrors Python: ts = [t0 + i * (1 - t0) / nsteps for i in range(nsteps)]
std::vector<float> d3pm_ts(double t0, int nsteps) {
    std::vector<float> ts;
    const double step = (1.0 - t0) / nsteps;
    for (int i = 0; i < nsteps; ++i) ts.push_back(static_cast<float>(t0 + i * step));
    return ts;
}

}  // namespace

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

Model::Model() = default;
Model::~Model() = default;

int read_model_config(const std::string& model_dir, Model& out) {
    const std::string path = join_path(model_dir, "config.json");
    std::string text;
    if (!read_text_file(path, text)) return fail(KE_ERR_MODEL, "GAME: cannot read %s", path.c_str());
    try {
        json cfg = json::parse(text);
        if (!cfg.is_object()) return fail(KE_ERR_MODEL, "GAME: %s is not a JSON object", path.c_str());
        out.model_dir = model_dir;
        out.name = basename_of(model_dir);
        if (cfg.contains("samplerate") && cfg["samplerate"].is_number()) out.samplerate = cfg["samplerate"].get<int>();
        if (cfg.contains("timestep") && cfg["timestep"].is_number()) out.timestep = cfg["timestep"].get<double>();
        if (cfg.contains("loop") && cfg["loop"].is_boolean()) out.loop = cfg["loop"].get<bool>();
        out.languages.clear();
        if (cfg.contains("languages") && cfg["languages"].is_object()) {
            for (auto it = cfg["languages"].begin(); it != cfg["languages"].end(); ++it) {
                if (it.value().is_number_integer()) out.languages[it.key()] = it.value().get<int>();
            }
        }
    } catch (const std::exception& e) {
        return fail(KE_ERR_MODEL, "GAME: invalid %s: %s", path.c_str(), e.what());
    }
    if (out.samplerate <= 0 || !(out.timestep > 0)) {
        return fail(KE_ERR_MODEL, "GAME: invalid samplerate/timestep in %s", path.c_str());
    }
    return KE_OK;
}

std::unique_ptr<Model> Model::load(ke_runtime* rt, const std::string& model_dir, std::string* error) {
    auto m = std::make_unique<Model>();
    if (read_model_config(model_dir, *m) != KE_OK) {
        if (error) *error = ke_last_error();
        return nullptr;
    }
    struct Entry { const char* file; std::unique_ptr<OrtSession>* slot; };
    const Entry entries[] = {
        {"encoder.onnx", &m->encoder}, {"segmenter.onnx", &m->segmenter}, {"estimator.onnx", &m->estimator},
        {"dur2bd.onnx", &m->dur2bd}, {"bd2dur.onnx", &m->bd2dur},
    };
    for (const Entry& e : entries) {
        std::string err;
        auto t0 = std::chrono::steady_clock::now();
        *e.slot = OrtSession::create(rt, join_path(model_dir, e.file), &err);
        if (!*e.slot) {
            if (error) *error = err;
            fail(KE_ERR_MODEL, "GAME: cannot load %s: %s", e.file, err.c_str());
            return nullptr;
        }
        auto t1 = std::chrono::steady_clock::now();
        KE_LOGD("GAME: loaded %s in %.0f ms", e.file, std::chrono::duration<double, std::milli>(t1 - t0).count());
    }
    return m;
}

int Model::language_id(const std::string& name) const {
    if (name.empty()) return 0;
    auto it = languages.find(name);
    return it == languages.end() ? 0 : it->second;
}

int Model::run_chunk(const float* wav, size_t n, double offset_seconds, const Options& opt,
                     std::vector<Note>& notes, ke_progress_cb progress, void* user,
                     float progress_begin, float progress_end) {
    if (n == 0) return KE_OK;
    auto prog = [&](float local, const char* stage) {
        return report_progress(progress, user, progress_begin + (progress_end - progress_begin) * local, stage);
    };
    const float length = static_cast<float>(static_cast<double>(n) / samplerate);   // Python: chunk length in s
    std::vector<TensorOut> outs;

    // --- encoder ---------------------------------------------------------
    {
        const float duration = length;
        int rc = encoder->run({tensor_f32("waveform", {1, static_cast<int64_t>(n)}, wav),
                               tensor_f32("duration", {1}, &duration)},
                              {"x_seg", "x_est", "maskT"}, outs);
        if (rc != KE_OK) return rc;
    }
    TensorOut x_seg = std::move(outs[0]);
    TensorOut x_est = std::move(outs[1]);
    TensorOut maskT_out = std::move(outs[2]);
    int rc = check_output(x_seg, "x_seg", ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, 3);
    if (rc == KE_OK) rc = check_output(x_est, "x_est", ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, 3);
    if (rc == KE_OK) rc = check_output(maskT_out, "maskT", ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL, 2);
    if (rc != KE_OK) return rc;
    const int64_t T = maskT_out.shape[1];
    const int64_t C = x_seg.shape[2];
    std::vector<uint8_t> maskT(maskT_out.data.begin(), maskT_out.data.end());
    if ((rc = prog(0.1f, "encoder")) != KE_OK) return rc;

    // --- known boundaries from the single known duration -----------------
    std::vector<uint8_t> known_boundaries;
    {
        const float known_durations[1] = {length};
        rc = dur2bd->run({tensor_f32("durations", {1, 1}, known_durations),
                          tensor_bool("maskT", {1, T}, as_bool(maskT))},
                         {"boundaries"}, outs);
        if (rc != KE_OK) return rc;
        if ((rc = check_output(outs[0], "boundaries", ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL, 2)) != KE_OK) return rc;
        known_boundaries.assign(outs[0].data.begin(), outs[0].data.end());
    }

    // --- segmenter: D3PM sampling loop -----------------------------------
    std::vector<uint8_t> boundaries = known_boundaries;
    {
        const int64_t language = opt.language_id;
        const float threshold = opt.seg_threshold;
        const int64_t radius = py_round(static_cast<double>(opt.seg_radius_seconds) / timestep);
        const std::vector<float> ts = loop ? d3pm_ts(opt.t0, opt.nsteps) : std::vector<float>{0.f};
        for (size_t i = 0; i < ts.size(); ++i) {
            const float t = ts[i];
            std::vector<TensorView> inputs = {
                tensor_f32("x_seg", {1, T, C}, x_seg.f32()),
                tensor_i64("language", {1}, &language),
                tensor_bool("known_boundaries", {1, T}, as_bool(known_boundaries)),
                tensor_bool("prev_boundaries", {1, T}, as_bool(boundaries)),
                tensor_f32("t", {1}, &t),
                tensor_bool("maskT", {1, T}, as_bool(maskT)),
                tensor_f32_scalar("threshold", &threshold),
                tensor_i64_scalar("radius", &radius),
            };
            // Models without the sampling loop / languages omit those inputs.
            inputs.erase(std::remove_if(inputs.begin(), inputs.end(),
                                        [&](const TensorView& v) { return !segmenter->has_input(v.name); }),
                         inputs.end());
            rc = segmenter->run(inputs, {"boundaries"}, outs);
            if (rc != KE_OK) return rc;
            if ((rc = check_output(outs[0], "boundaries", ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL, 2)) != KE_OK) return rc;
            if (outs[0].shape[1] != T) return fail(KE_ERR_MODEL, "GAME: segmenter returned T=%lld, expected %lld",
                                                   static_cast<long long>(outs[0].shape[1]), static_cast<long long>(T));
            boundaries.assign(outs[0].data.begin(), outs[0].data.end());
            if ((rc = prog(0.1f + 0.7f * static_cast<float>(i + 1) / ts.size(), "segmenter")) != KE_OK) return rc;
        }
    }

    // --- boundaries -> durations -----------------------------------------
    std::vector<float> durations;
    std::vector<uint8_t> maskN;
    {
        rc = bd2dur->run({tensor_bool("boundaries", {1, T}, as_bool(boundaries)),
                          tensor_bool("maskT", {1, T}, as_bool(maskT))},
                         {"durations", "maskN"}, outs);
        if (rc != KE_OK) return rc;
        if ((rc = check_output(outs[0], "durations", ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, 2)) != KE_OK) return rc;
        if ((rc = check_output(outs[1], "maskN", ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL, 2)) != KE_OK) return rc;
        durations.assign(outs[0].f32(), outs[0].f32() + outs[0].count());
        maskN.assign(outs[1].data.begin(), outs[1].data.end());
    }
    const int64_t N = static_cast<int64_t>(durations.size());
    if (static_cast<int64_t>(maskN.size()) != N) return fail(KE_ERR_MODEL, "GAME: bd2dur durations/maskN size mismatch");

    // --- estimator --------------------------------------------------------
    std::vector<uint8_t> presence;
    std::vector<float> scores;
    {
        const float threshold = opt.est_threshold;
        rc = estimator->run({tensor_f32("x_est", {1, T, C}, x_est.f32()),
                             tensor_bool("boundaries", {1, T}, as_bool(boundaries)),
                             tensor_bool("maskT", {1, T}, as_bool(maskT)),
                             tensor_bool("maskN", {1, N}, as_bool(maskN)),
                             tensor_f32_scalar("threshold", &threshold)},
                            {"presence", "scores"}, outs);
        if (rc != KE_OK) return rc;
        if ((rc = check_output(outs[0], "presence", ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL, 2)) != KE_OK) return rc;
        if ((rc = check_output(outs[1], "scores", ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, 2)) != KE_OK) return rc;
        presence.assign(outs[0].data.begin(), outs[0].data.end());
        scores.assign(outs[1].f32(), outs[1].f32() + outs[1].count());
        if (static_cast<int64_t>(presence.size()) != N || static_cast<int64_t>(scores.size()) != N) {
            return fail(KE_ERR_MODEL, "GAME: estimator output size mismatch (N=%lld)", static_cast<long long>(N));
        }
    }
    if ((rc = prog(0.95f, "estimator")) != KE_OK) return rc;

    // --- notes (SaveCombinedFileCallback.on_predict_batch_end) -------------
    // float32 arithmetic on purpose: the reference computes cumsum/clamp/add on
    // float32 tensors.
    const float offset_f = static_cast<float>(offset_seconds);
    float cum = 0.f;
    for (int64_t k = 0; k < N; ++k) {
        const float onset_raw = std::min(cum, length);
        cum += durations[static_cast<size_t>(k)];
        const float offset_raw = std::min(cum, length);
        const float onset = onset_raw + offset_f;
        const float note_off = offset_raw + offset_f;
        if (static_cast<double>(note_off) - static_cast<double>(onset) <= 0.0) continue;
        if (!presence[static_cast<size_t>(k)]) continue;
        Note nt;
        nt.onset = onset;
        nt.offset = note_off;
        nt.pitch = scores[static_cast<size_t>(k)];
        notes.push_back(nt);
    }
    return KE_OK;
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

int parse_options(const std::string& text, const std::string& model_dir, Options& out, std::string* language_name) {
    Model cfg;
    const bool have_cfg = read_model_config(model_dir, cfg) == KE_OK;
    if (language_name) language_name->clear();
    out = Options{};
    try {
        json j = text.empty() ? json::object() : json::parse(text);
        if (j.is_null()) j = json::object();
        if (!j.is_object()) return fail(KE_ERR_INVALID_ARG, "GAME options must be a JSON object");

        auto get_num = [&](const json& o, const char* key, double& v) -> int {
            if (!o.contains(key) || o[key].is_null()) return KE_OK;
            if (!o[key].is_number()) return fail(KE_ERR_INVALID_ARG, "GAME option '%s' must be a number", key);
            v = o[key].get<double>();
            return KE_OK;
        };
        double v;
        int rc;
        if (j.contains("language") && !j["language"].is_null()) {
            if (!j["language"].is_string()) return fail(KE_ERR_INVALID_ARG, "GAME option 'language' must be a string");
            const std::string lang = j["language"].get<std::string>();
            if (language_name) *language_name = lang;
            out.language_id = have_cfg ? cfg.language_id(lang) : 0;
            if (!lang.empty() && out.language_id == 0) {
                KE_LOGW("GAME: language '%s' not supported by this model, using universal (0)", lang.c_str());
            }
        }
        v = out.seg_threshold;      if ((rc = get_num(j, "seg_threshold", v)) != KE_OK) return rc;      out.seg_threshold = float(v);
        v = out.seg_radius_seconds; if ((rc = get_num(j, "seg_radius_seconds", v)) != KE_OK) return rc; out.seg_radius_seconds = float(v);
        v = out.t0;                 if ((rc = get_num(j, "t0", v)) != KE_OK) return rc;                 out.t0 = float(v);
        v = out.nsteps;             if ((rc = get_num(j, "nsteps", v)) != KE_OK) return rc;             out.nsteps = int(v);
        v = out.est_threshold;      if ((rc = get_num(j, "est_threshold", v)) != KE_OK) return rc;      out.est_threshold = float(v);
        v = out.max_chunk_seconds;  if ((rc = get_num(j, "max_chunk_seconds", v)) != KE_OK) return rc;  out.max_chunk_seconds = v;
        if (j.contains("slicer") && !j["slicer"].is_null()) {
            const json& s = j["slicer"];
            if (!s.is_object()) return fail(KE_ERR_INVALID_ARG, "GAME option 'slicer' must be an object");
            v = out.slicer_threshold_db;    if ((rc = get_num(s, "threshold_db", v)) != KE_OK) return rc;    out.slicer_threshold_db = float(v);
            v = out.slicer_min_length_ms;   if ((rc = get_num(s, "min_length_ms", v)) != KE_OK) return rc;   out.slicer_min_length_ms = int(v);
            v = out.slicer_min_interval_ms; if ((rc = get_num(s, "min_interval_ms", v)) != KE_OK) return rc; out.slicer_min_interval_ms = int(v);
            v = out.slicer_hop_ms;          if ((rc = get_num(s, "hop_ms", v)) != KE_OK) return rc;          out.slicer_hop_ms = int(v);
            v = out.slicer_max_sil_kept_ms; if ((rc = get_num(s, "max_sil_kept_ms", v)) != KE_OK) return rc; out.slicer_max_sil_kept_ms = int(v);
        }
    } catch (const std::exception& e) {
        return fail(KE_ERR_INVALID_ARG, "GAME: invalid options JSON: %s", e.what());
    }
    // Same ranges as infer.py's click options.
    if (!(out.seg_threshold >= 0.f && out.seg_threshold < 1.f)) return fail(KE_ERR_INVALID_ARG, "GAME: seg_threshold must be in [0,1)");
    if (!(out.est_threshold >= 0.f && out.est_threshold < 1.f)) return fail(KE_ERR_INVALID_ARG, "GAME: est_threshold must be in [0,1)");
    if (!(out.t0 >= 0.f && out.t0 < 1.f)) return fail(KE_ERR_INVALID_ARG, "GAME: t0 must be in [0,1)");
    if (out.nsteps < 1) return fail(KE_ERR_INVALID_ARG, "GAME: nsteps must be >= 1");
    if (!(out.seg_radius_seconds > 0.f)) return fail(KE_ERR_INVALID_ARG, "GAME: seg_radius_seconds must be > 0");
    if (!(out.max_chunk_seconds > 0.0)) return fail(KE_ERR_INVALID_ARG, "GAME: max_chunk_seconds must be > 0");
    SlicerParams sp;
    sp.sr = have_cfg ? cfg.samplerate : 44100;
    sp.threshold_db = out.slicer_threshold_db;
    sp.min_length_ms = out.slicer_min_length_ms;
    sp.min_interval_ms = out.slicer_min_interval_ms;
    sp.hop_ms = out.slicer_hop_ms;
    sp.max_sil_kept_ms = out.slicer_max_sil_kept_ms;
    std::string why;
    if (!validate_slicer_params(sp, &why)) return fail(KE_ERR_INVALID_ARG, "GAME: %s", why.c_str());
    return KE_OK;
}

// ---------------------------------------------------------------------------
// Merging + output
// ---------------------------------------------------------------------------

void merge_notes(std::vector<Note>& notes) {
    std::stable_sort(notes.begin(), notes.end(), [](const Note& a, const Note& b) {
        if (a.onset != b.onset) return a.onset < b.onset;
        if (a.offset != b.offset) return a.offset < b.offset;
        return a.pitch < b.pitch;
    });
    std::vector<Note> kept;
    kept.reserve(notes.size());
    double last_time = 0.0;
    for (Note n : notes) {
        n.onset = std::max(n.onset, last_time);
        n.offset = std::max(n.offset, n.onset);
        if (n.offset <= n.onset) continue;
        last_time = n.offset;
        kept.push_back(n);
    }
    notes.swap(kept);
}

std::string notes_to_json(const std::vector<Note>& notes, double timestep, const std::string& language,
                          const std::string& model_name) {
    json j;
    j["timestep"] = timestep;
    j["language"] = language;
    j["model"] = model_name;
    json arr = json::array();
    for (const Note& n : notes) {
        arr.push_back({{"onset", n.onset}, {"offset", n.offset}, {"pitch", n.pitch}});
    }
    j["notes"] = std::move(arr);
    return j.dump();
}

// ---------------------------------------------------------------------------
// Drivers
// ---------------------------------------------------------------------------

int transcribe_waveform(Model& model, const std::vector<float>& mono, const Options& opt,
                        std::vector<Note>& notes, ke_progress_cb progress, void* user) {
    notes.clear();
    if (mono.empty()) return fail(KE_ERR_INVALID_ARG, "GAME: empty waveform");

    SlicerParams sp;
    sp.sr = model.samplerate;
    sp.threshold_db = opt.slicer_threshold_db;
    sp.min_length_ms = opt.slicer_min_length_ms;
    sp.min_interval_ms = opt.slicer_min_interval_ms;
    sp.hop_ms = opt.slicer_hop_ms;
    sp.max_sil_kept_ms = opt.slicer_max_sil_kept_ms;
    std::string why;
    if (!validate_slicer_params(sp, &why)) return fail(KE_ERR_INVALID_ARG, "GAME: %s", why.c_str());

    int rc = report_progress(progress, user, 0.f, "slice");
    if (rc != KE_OK) return rc;
    std::vector<Slice> slices = slice_waveform(mono, sp);
    const SlicerFrames frames = resolve_slicer_frames(sp);
    const size_t max_samples = static_cast<size_t>(std::llround(opt.max_chunk_seconds * model.samplerate));
    const size_t before_split = slices.size();
    slices = split_long_slices(mono, slices, frames, std::max<size_t>(1, max_samples));
    KE_LOGI("GAME: %zu slice(s) (%zu before the %.1f s cap), language id %d, nsteps %d",
            slices.size(), before_split, opt.max_chunk_seconds, opt.language_id, opt.nsteps);
    for (size_t i = 0; i < slices.size(); ++i) {
        KE_LOGD("GAME: slice %zu: %.3f .. %.3f s", i, double(slices[i].begin) / model.samplerate,
                double(slices[i].end) / model.samplerate);
    }

    for (size_t i = 0; i < slices.size(); ++i) {
        const Slice& s = slices[i];
        const float p0 = static_cast<float>(i) / slices.size();
        const float p1 = static_cast<float>(i + 1) / slices.size();
        rc = model.run_chunk(mono.data() + s.begin, s.length(), double(s.begin) / model.samplerate, opt,
                             notes, progress, user, p0, p1);
        if (rc != KE_OK) return rc;
    }
    merge_notes(notes);
    return report_progress(progress, user, 1.f, "done");
}

int transcribe_waveform(ke_runtime* rt, const std::string& model_dir, const std::vector<float>& mono44k,
                        const Options& opt, std::vector<Note>& notes, ke_progress_cb progress, void* user) {
    std::string err;
    auto model = Model::load(rt, model_dir, &err);
    if (!model) return KE_ERR_MODEL;   // ke_last_error already set
    return transcribe_waveform(*model, mono44k, opt, notes, progress, user);
}

int transcribe(ke_runtime* rt, const std::string& model_dir, const std::string& input_wav,
               const std::string& options_json, const std::string& notes_out_json,
               ke_progress_cb progress, void* user) {
    if (!rt) return fail(KE_ERR_INVALID_ARG, "runtime is null");
    if (model_dir.empty()) return fail(KE_ERR_INVALID_ARG, "model_dir is empty");
    if (input_wav.empty()) return fail(KE_ERR_INVALID_ARG, "input_wav is empty");
    if (notes_out_json.empty()) return fail(KE_ERR_INVALID_ARG, "notes_out_json is empty");

    Options opt;
    std::string language;
    int rc = parse_options(options_json, model_dir, opt, &language);
    if (rc != KE_OK) return rc;

    if ((rc = report_progress(progress, user, 0.f, "decode")) != KE_OK) return rc;
    AudioBuffer buf;
    if ((rc = read_wav(input_wav, buf)) != KE_OK) return rc;
    if (buf.frames() == 0) return fail(KE_ERR_INVALID_ARG, "GAME: %s contains no audio", input_wav.c_str());

    if ((rc = report_progress(progress, user, 0.f, "load")) != KE_OK) return rc;
    auto t_load0 = std::chrono::steady_clock::now();
    std::string err;
    auto model = Model::load(rt, model_dir, &err);
    if (!model) return KE_ERR_MODEL;
    auto t_load1 = std::chrono::steady_clock::now();
    KE_LOGI("GAME: model '%s' loaded in %.2f s", model->name.c_str(),
            std::chrono::duration<double>(t_load1 - t_load0).count());

    std::vector<float> mono = buf.channels == 1 ? std::move(buf.planes[0]) : to_mono(buf);
    if (buf.sample_rate != model->samplerate) {
        KE_LOGI("GAME: resampling %d Hz -> %d Hz", buf.sample_rate, model->samplerate);
        mono = resample(mono, buf.sample_rate, model->samplerate);
    }

    std::vector<Note> notes;
    auto t_run0 = std::chrono::steady_clock::now();
    rc = transcribe_waveform(*model, mono, opt, notes, progress, user);
    if (rc != KE_OK) return rc;
    auto t_run1 = std::chrono::steady_clock::now();
    KE_LOGI("GAME: %zu notes from %.1f s of audio in %.2f s", notes.size(),
            double(mono.size()) / model->samplerate, std::chrono::duration<double>(t_run1 - t_run0).count());

    const std::string out = notes_to_json(notes, model->timestep, language, model->name);
    std::ofstream f(notes_out_json, std::ios::binary | std::ios::trunc);
    if (!f) return fail(KE_ERR_IO, "GAME: cannot write %s", notes_out_json.c_str());
    f << out;
    if (!f) return fail(KE_ERR_IO, "GAME: write failed: %s", notes_out_json.c_str());
    return KE_OK;
}

}  // namespace ke::game
