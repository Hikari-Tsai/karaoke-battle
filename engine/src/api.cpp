// C API entry points that forward to the internal C++ modules.
// (ke_audio_* functions are implemented in audio/audio_engine.cpp,
//  ke_version/ke_last_error/ke_set_log_callback in core/error.cpp.)
#include "karaoke_engine.h"

#include "core/error.h"
#include "core/gpu_info.h"
#include "core/ort_runtime.h"
#include "models/game.h"
#include "models/mdx.h"
#include "models/swiftf0.h"

extern "C" {

KE_API int ke_runtime_create(const char* ort_library_path, int ep, int device_id, int num_threads, ke_runtime** out) {
    return ke::runtime_create(ort_library_path, ep, device_id, num_threads, out);
}

KE_API void ke_runtime_destroy(ke_runtime* rt) { ke::runtime_destroy(rt); }

KE_API int ke_runtime_active_ep(const ke_runtime* rt) { return rt ? rt->active_ep : KE_ERR_INVALID_ARG; }

KE_API int ke_runtime_info_json(const ke_runtime* rt, char* out, size_t cap, size_t* needed) {
    if (!rt) return ke::fail(KE_ERR_INVALID_ARG, "runtime is null");
    return ke::write_out_string(ke::runtime_info_json(rt), out, cap, needed);
}

KE_API int ke_runtime_selftest(ke_runtime* rt, const char* model_path_or_null, double* ms_out) {
    return ke::runtime_selftest(rt, model_path_or_null, ms_out);
}

KE_API int ke_system_gpu_info_json(char* out, size_t cap, size_t* needed) {
    return ke::write_out_string(ke::gpu_info_json(), out, cap, needed);
}

KE_API int ke_separate(ke_runtime* rt, const char* model_path, const char* params_json, const char* input_wav,
                       const char* primary_out_wav, const char* secondary_out_wav,
                       ke_progress_cb progress, void* user) {
    if (!rt || !model_path || !input_wav) return ke::fail(KE_ERR_INVALID_ARG, "ke_separate: null argument");
    return ke::mdx::separate(rt, model_path, params_json ? params_json : "{}", input_wav,
                             primary_out_wav ? primary_out_wav : "", secondary_out_wav ? secondary_out_wav : "",
                             progress, user);
}

KE_API int ke_transcribe(ke_runtime* rt, const char* model_dir, const char* input_wav, const char* options_json,
                         const char* notes_out_json, ke_progress_cb progress, void* user) {
    if (!rt || !model_dir || !input_wav || !notes_out_json) return ke::fail(KE_ERR_INVALID_ARG, "ke_transcribe: null argument");
    return ke::game::transcribe(rt, model_dir, input_wav, options_json ? options_json : "{}", notes_out_json, progress, user);
}

KE_API int ke_f0_extract(ke_runtime* rt, const char* swiftf0_model_path, const char* input_wav, float fmin, float fmax,
                         const char* f0_out_json, ke_progress_cb progress, void* user) {
    if (!rt || !swiftf0_model_path || !input_wav || !f0_out_json) return ke::fail(KE_ERR_INVALID_ARG, "ke_f0_extract: null argument");
    return ke::swiftf0::extract_file(rt, swiftf0_model_path, input_wav, fmin, fmax, f0_out_json, progress, user);
}

}  // extern "C"
