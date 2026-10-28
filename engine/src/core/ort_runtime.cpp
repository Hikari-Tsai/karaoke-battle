#include "core/ort_runtime.h"

#include <chrono>
#include <cstring>
#include <filesystem>

#include "core/error.h"
#include "nlohmann/json.hpp"

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#else
#  include <dlfcn.h>
#endif

namespace fs = std::filesystem;

namespace ke {

const char* ep_name(int ep) {
    switch (ep) {
        case KE_EP_CPU: return "cpu";
        case KE_EP_CUDA: return "cuda";
        case KE_EP_DIRECTML: return "directml";
        case KE_EP_COREML: return "coreml";
        default: return "unknown";
    }
}

namespace {

void* sym(void* handle, const char* name) {
#if defined(_WIN32)
    return reinterpret_cast<void*>(GetProcAddress(static_cast<HMODULE>(handle), name));
#else
    return dlsym(handle, name);
#endif
}

std::string ort_err_to_string(const OrtApi* api, OrtStatus* st) {
    std::string s = api->GetErrorMessage(st);
    api->ReleaseStatus(st);
    return s;
}

#define ORT_CHECK(rt, expr, ctx)                                                      \
    do {                                                                              \
        OrtStatus* _st = (expr);                                                      \
        if (_st) {                                                                    \
            std::string _m = ort_err_to_string((rt)->api, _st);                       \
            return ::ke::fail(KE_ERR_ORT, "%s: %s", ctx, _m.c_str());                 \
        }                                                                             \
    } while (0)

size_t elem_size(ONNXTensorElementDataType t) {
    switch (t) {
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT: return 4;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE: return 8;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64: return 8;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32: return 4;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL: return 1;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8: return 1;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16: return 2;
        default: return 0;
    }
}

// Appends the requested EP to the session options. Returns KE_OK when the EP
// was registered, otherwise an error code (ep_error filled by caller).
int append_ep(ke_runtime* rt, OrtSessionOptions* so, std::string* err) {
    const OrtApi* api = rt->api;
    switch (rt->requested_ep) {
        case KE_EP_CPU:
            return KE_OK;
        case KE_EP_CUDA: {
            OrtCUDAProviderOptionsV2* opts = nullptr;
            OrtStatus* st = api->CreateCUDAProviderOptions(&opts);
            if (st) { *err = ort_err_to_string(api, st); return KE_ERR_EP_UNAVAILABLE; }
            const char* keys[] = {"device_id", "cudnn_conv_algo_search"};
            std::string dev = std::to_string(rt->device_id);
            const char* vals[] = {dev.c_str(), "HEURISTIC"};
            st = api->UpdateCUDAProviderOptions(opts, keys, vals, 2);
            if (!st) st = api->SessionOptionsAppendExecutionProvider_CUDA_V2(so, opts);
            api->ReleaseCUDAProviderOptions(opts);
            if (st) { *err = ort_err_to_string(api, st); return KE_ERR_EP_UNAVAILABLE; }
            return KE_OK;
        }
        case KE_EP_DIRECTML: {
            // DirectML builds export this generic registration since ORT 1.17.
            const char* keys[] = {"device_id"};
            std::string dev = std::to_string(rt->device_id);
            const char* vals[] = {dev.c_str()};
            OrtStatus* st = api->SessionOptionsAppendExecutionProvider(so, "DML", keys, vals, 1);
            if (st) {
                *err = ort_err_to_string(api, st);
                // Older DML builds only export the dedicated factory function.
                using DmlFn = OrtStatus* (*)(OrtSessionOptions*, int);
                auto fn = reinterpret_cast<DmlFn>(sym(rt->lib_handle, "OrtSessionOptionsAppendExecutionProvider_DML"));
                if (!fn) return KE_ERR_EP_UNAVAILABLE;
                st = fn(so, rt->device_id);
                if (st) { *err = ort_err_to_string(api, st); return KE_ERR_EP_UNAVAILABLE; }
                err->clear();
            }
            // DirectML requires sequential execution and no memory pattern.
            api->DisableMemPattern(so);
            api->SetSessionExecutionMode(so, ORT_SEQUENTIAL);
            return KE_OK;
        }
        case KE_EP_COREML: {
            const char* keys[] = {"ModelFormat", "MLComputeUnits", "AllowLowPrecisionAccumulationOnGPU"};
            const char* vals[] = {"MLProgram", "ALL", "0"};
            OrtStatus* st = api->SessionOptionsAppendExecutionProvider(so, "CoreML", keys, vals, 3);
            if (st) { *err = ort_err_to_string(api, st); return KE_ERR_EP_UNAVAILABLE; }
            return KE_OK;
        }
        default:
            *err = "unknown execution provider";
            return KE_ERR_INVALID_ARG;
    }
}

void ort_log_bridge(void*, OrtLoggingLevel severity, const char*, const char*, const char*, const char* message) {
    int lvl = severity >= ORT_LOGGING_LEVEL_ERROR ? KE_LOG_ERROR
            : severity == ORT_LOGGING_LEVEL_WARNING ? KE_LOG_WARN : KE_LOG_DEBUG;
    ke::log(lvl, "ort: %s", message);
}

}  // namespace

// ---------------------------------------------------------------------------
// runtime
// ---------------------------------------------------------------------------

int runtime_create(const char* ort_library_path, int ep, int device_id, int num_threads, ke_runtime** out) {
    if (!out) return fail(KE_ERR_INVALID_ARG, "out is null");
    *out = nullptr;
    if (!ort_library_path || !*ort_library_path) return fail(KE_ERR_INVALID_ARG, "ort_library_path is empty");
    if (!fs::exists(ort_library_path)) return fail(KE_ERR_ORT_LOAD, "onnxruntime library not found: %s", ort_library_path);

    auto rt = std::make_unique<ke_runtime>();
    rt->lib_path = ort_library_path;
    rt->lib_dir = fs::path(ort_library_path).parent_path().string();
    rt->requested_ep = ep;
    rt->device_id = device_id;
    rt->num_threads = num_threads;

#if defined(_WIN32)
    // Make provider DLLs next to onnxruntime.dll resolvable (CUDA pack, DirectML.dll).
    std::wstring wdir = fs::path(rt->lib_dir).wstring();
    SetDllDirectoryW(wdir.c_str());
    std::wstring wpath = fs::path(rt->lib_path).wstring();
    rt->lib_handle = LoadLibraryExW(wpath.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR);
    if (!rt->lib_handle) {
        return fail(KE_ERR_ORT_LOAD, "LoadLibrary failed for %s (error %lu)", ort_library_path, GetLastError());
    }
#else
    rt->lib_handle = dlopen(ort_library_path, RTLD_NOW | RTLD_LOCAL);
    if (!rt->lib_handle) {
        return fail(KE_ERR_ORT_LOAD, "dlopen failed for %s: %s", ort_library_path, dlerror());
    }
#endif
    using GetBaseFn = const OrtApiBase* (*)(void);
    auto get_base = reinterpret_cast<GetBaseFn>(sym(rt->lib_handle, "OrtGetApiBase"));
    if (!get_base) return fail(KE_ERR_ORT_LOAD, "OrtGetApiBase not exported by %s", ort_library_path);
    rt->api_base = get_base();
    rt->ort_version = rt->api_base->GetVersionString();
    rt->api = rt->api_base->GetApi(ORT_API_VERSION);
    if (!rt->api) {
        return fail(KE_ERR_ORT_LOAD, "onnxruntime %s does not provide API version %d",
                    rt->ort_version.c_str(), ORT_API_VERSION);
    }
    OrtStatus* st = rt->api->CreateEnvWithCustomLogger(ort_log_bridge, nullptr, ORT_LOGGING_LEVEL_WARNING,
                                                        "karaoke_engine", &rt->env);
    if (st) return fail(KE_ERR_ORT, "CreateEnv: %s", ort_err_to_string(rt->api, st).c_str());

    // Probe the EP once with an empty session options object so the app can
    // tell immediately whether CUDA/DirectML are usable on this machine.
    rt->active_ep = KE_EP_CPU;
    if (ep != KE_EP_CPU) {
        OrtSessionOptions* so = nullptr;
        st = rt->api->CreateSessionOptions(&so);
        if (st) return fail(KE_ERR_ORT, "CreateSessionOptions: %s", ort_err_to_string(rt->api, st).c_str());
        std::string err;
        int rc = append_ep(rt.get(), so, &err);
        rt->api->ReleaseSessionOptions(so);
        if (rc == KE_OK) {
            rt->active_ep = ep;
        } else {
            rt->ep_error = err;
            KE_LOGW("execution provider %s unavailable, using CPU: %s", ep_name(ep), err.c_str());
        }
    }
    KE_LOGI("onnxruntime %s loaded from %s (ep=%s)", rt->ort_version.c_str(), ort_library_path, ep_name(rt->active_ep));
    *out = rt.release();
    return KE_OK;
}

void runtime_destroy(ke_runtime* rt) {
    if (!rt) return;
    if (rt->env && rt->api) rt->api->ReleaseEnv(rt->env);
    if (rt->lib_handle) {
#if defined(_WIN32)
        FreeLibrary(static_cast<HMODULE>(rt->lib_handle));
#else
        dlclose(rt->lib_handle);
#endif
    }
    delete rt;
}

std::string runtime_info_json(const ke_runtime* rt) {
    nlohmann::json j;
    j["ort_version"] = rt->ort_version;
    j["library"] = rt->lib_path;
    j["requested_ep"] = ep_name(rt->requested_ep);
    j["ep"] = ep_name(rt->active_ep);
    j["ep_available"] = rt->active_ep == rt->requested_ep;
    j["device_id"] = rt->device_id;
    j["error"] = rt->ep_error;
    j["api_version"] = ORT_API_VERSION;
    return j.dump();
}

// ---------------------------------------------------------------------------
// session
// ---------------------------------------------------------------------------

size_t TensorOut::count() const {
    size_t n = 1;
    for (auto d : shape) n *= static_cast<size_t>(d < 0 ? 0 : d);
    return n;
}

TensorView tensor_f32(const char* name, std::vector<int64_t> shape, const float* data) {
    TensorView t; t.name = name; t.type = ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT; t.shape = std::move(shape);
    size_t n = 1; for (auto d : t.shape) n *= static_cast<size_t>(d);
    t.data = data; t.bytes = n * sizeof(float); return t;
}
TensorView tensor_f32_scalar(const char* name, const float* value) {
    TensorView t; t.name = name; t.type = ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT; t.data = value; t.bytes = sizeof(float); return t;
}
TensorView tensor_i64(const char* name, std::vector<int64_t> shape, const int64_t* data) {
    TensorView t; t.name = name; t.type = ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64; t.shape = std::move(shape);
    size_t n = 1; for (auto d : t.shape) n *= static_cast<size_t>(d);
    t.data = data; t.bytes = n * sizeof(int64_t); return t;
}
TensorView tensor_i64_scalar(const char* name, const int64_t* value) {
    TensorView t; t.name = name; t.type = ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64; t.data = value; t.bytes = sizeof(int64_t); return t;
}
TensorView tensor_bool(const char* name, std::vector<int64_t> shape, const bool* data) {
    TensorView t; t.name = name; t.type = ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL; t.shape = std::move(shape);
    size_t n = 1; for (auto d : t.shape) n *= static_cast<size_t>(d);
    t.data = data; t.bytes = n; return t;
}

std::unique_ptr<OrtSession> OrtSession::create(ke_runtime* rt, const std::string& model_path, std::string* error) {
    auto set_err = [&](const std::string& m) { if (error) *error = m; fail_str(KE_ERR_ORT, m); };
    if (!rt || !rt->api) { set_err("runtime is null"); return nullptr; }
    if (!fs::exists(model_path)) { set_err("model not found: " + model_path); return nullptr; }
    const OrtApi* api = rt->api;

    auto make_options = [&](bool with_ep, std::string* ep_err) -> OrtSessionOptions* {
        OrtSessionOptions* so = nullptr;
        OrtStatus* st = api->CreateSessionOptions(&so);
        if (st) { set_err("CreateSessionOptions: " + ort_err_to_string(api, st)); return nullptr; }
        api->SetSessionGraphOptimizationLevel(so, ORT_ENABLE_ALL);
        if (rt->num_threads > 0) api->SetIntraOpNumThreads(so, rt->num_threads);
        api->SetSessionLogSeverityLevel(so, ORT_LOGGING_LEVEL_WARNING);
        if (with_ep && rt->requested_ep != KE_EP_CPU) {
            if (append_ep(rt, so, ep_err) != KE_OK) { api->ReleaseSessionOptions(so); return nullptr; }
        }
        return so;
    };

    std::unique_ptr<OrtSession> s(new OrtSession());
    s->rt_ = rt;
    ::OrtSession* raw = nullptr;
    std::string ep_err;
    OrtSessionOptions* so = make_options(rt->active_ep != KE_EP_CPU, &ep_err);
    OrtStatus* st = nullptr;
    if (so) {
#if defined(_WIN32)
        std::wstring wpath = fs::path(model_path).wstring();
        st = api->CreateSession(rt->env, wpath.c_str(), so, &raw);
#else
        st = api->CreateSession(rt->env, model_path.c_str(), so, &raw);
#endif
        api->ReleaseSessionOptions(so);
    }
    if (!so || st) {
        std::string m = st ? ort_err_to_string(api, st) : ep_err;
        if (rt->active_ep != KE_EP_CPU) {
            KE_LOGW("session on %s failed (%s), retrying on CPU", ep_name(rt->active_ep), m.c_str());
            rt->ep_error = m;
            so = make_options(false, nullptr);
            if (!so) return nullptr;
#if defined(_WIN32)
            std::wstring wpath = fs::path(model_path).wstring();
            st = api->CreateSession(rt->env, wpath.c_str(), so, &raw);
#else
            st = api->CreateSession(rt->env, model_path.c_str(), so, &raw);
#endif
            api->ReleaseSessionOptions(so);
            if (st) { set_err("CreateSession: " + ort_err_to_string(api, st)); return nullptr; }
        } else {
            set_err("CreateSession: " + m);
            return nullptr;
        }
    }
    s->raw_ = raw;
    st = api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &s->mem_);
    if (st) { set_err("CreateCpuMemoryInfo: " + ort_err_to_string(api, st)); return nullptr; }

    OrtAllocator* alloc = nullptr;
    api->GetAllocatorWithDefaultOptions(&alloc);
    size_t n_in = 0, n_out = 0;
    api->SessionGetInputCount(raw, &n_in);
    api->SessionGetOutputCount(raw, &n_out);
    for (size_t i = 0; i < n_in; ++i) {
        char* name = nullptr;
        api->SessionGetInputName(raw, i, alloc, &name);
        s->input_names_.emplace_back(name);
        alloc->Free(alloc, name);
    }
    for (size_t i = 0; i < n_out; ++i) {
        char* name = nullptr;
        api->SessionGetOutputName(raw, i, alloc, &name);
        s->output_names_.emplace_back(name);
        alloc->Free(alloc, name);
    }
    return s;
}

OrtSession::~OrtSession() {
    if (rt_ && rt_->api) {
        if (mem_) rt_->api->ReleaseMemoryInfo(mem_);
        if (raw_) rt_->api->ReleaseSession(raw_);
    }
}

bool OrtSession::has_input(const std::string& n) const {
    for (auto& s : input_names_) if (s == n) return true;
    return false;
}

int OrtSession::run(const std::vector<TensorView>& inputs, const std::vector<std::string>& output_names,
                    std::vector<TensorOut>& outputs) {
    const OrtApi* api = rt_->api;
    std::vector<OrtValue*> in_vals(inputs.size(), nullptr);
    std::vector<const char*> in_names(inputs.size());
    auto release_inputs = [&]() { for (auto* v : in_vals) if (v) api->ReleaseValue(v); };

    for (size_t i = 0; i < inputs.size(); ++i) {
        const TensorView& t = inputs[i];
        in_names[i] = t.name;
        OrtStatus* st = api->CreateTensorWithDataAsOrtValue(
            mem_, const_cast<void*>(t.data), t.bytes, t.shape.data(), t.shape.size(), t.type, &in_vals[i]);
        if (st) {
            std::string m = ort_err_to_string(api, st);
            release_inputs();
            return fail(KE_ERR_ORT, "CreateTensor(%s): %s", t.name, m.c_str());
        }
    }
    const std::vector<std::string>& names = output_names.empty() ? output_names_ : output_names;
    std::vector<const char*> out_names(names.size());
    for (size_t i = 0; i < names.size(); ++i) out_names[i] = names[i].c_str();
    std::vector<OrtValue*> out_vals(names.size(), nullptr);

    OrtStatus* st = api->Run(raw_, nullptr, in_names.data(), in_vals.data(), inputs.size(),
                             out_names.data(), names.size(), out_vals.data());
    release_inputs();
    if (st) return fail(KE_ERR_ORT, "Run: %s", ort_err_to_string(api, st).c_str());

    outputs.clear();
    outputs.resize(names.size());
    int rc = KE_OK;
    for (size_t i = 0; i < names.size(); ++i) {
        TensorOut& o = outputs[i];
        o.name = names[i];
        OrtTensorTypeAndShapeInfo* info = nullptr;
        st = api->GetTensorTypeAndShape(out_vals[i], &info);
        if (st) { rc = fail(KE_ERR_ORT, "GetTensorTypeAndShape: %s", ort_err_to_string(api, st).c_str()); break; }
        size_t dims = 0;
        api->GetDimensionsCount(info, &dims);
        o.shape.resize(dims);
        api->GetDimensions(info, o.shape.data(), dims);
        api->GetTensorElementType(info, &o.type);
        api->ReleaseTensorTypeAndShapeInfo(info);
        void* raw = nullptr;
        st = api->GetTensorMutableData(out_vals[i], &raw);
        if (st) { rc = fail(KE_ERR_ORT, "GetTensorMutableData: %s", ort_err_to_string(api, st).c_str()); break; }
        size_t bytes = o.count() * elem_size(o.type);
        o.data.resize(bytes);
        if (bytes) memcpy(o.data.data(), raw, bytes);
    }
    for (auto* v : out_vals) if (v) api->ReleaseValue(v);
    return rc;
}

// ---------------------------------------------------------------------------
// self test
// ---------------------------------------------------------------------------

int runtime_selftest(ke_runtime* rt, const char* model_path_or_null, double* ms_out) {
    if (!rt) return fail(KE_ERR_INVALID_ARG, "runtime is null");
    if (ms_out) *ms_out = 0;
    if (rt->requested_ep != KE_EP_CPU && rt->active_ep != rt->requested_ep) {
        return fail(KE_ERR_EP_UNAVAILABLE, "%s not available: %s", ep_name(rt->requested_ep), rt->ep_error.c_str());
    }
    if (!model_path_or_null || !*model_path_or_null) return KE_OK;

    std::string err;
    auto session = OrtSession::create(rt, model_path_or_null, &err);
    if (!session) return KE_ERR_ORT;
    if (rt->requested_ep != KE_EP_CPU && !rt->ep_error.empty()) {
        return fail(KE_ERR_EP_UNAVAILABLE, "model refused on %s: %s", ep_name(rt->requested_ep), rt->ep_error.c_str());
    }
    // We only time session creation + a run when the model has a single float input
    // whose shape we can satisfy with ones (used for the MDX/SwiftF0 smoke test).
    const OrtApi* api = rt->api;
    OrtTypeInfo* ti = nullptr;
    if (session->input_names().size() == 1 && api->SessionGetInputTypeInfo(session->raw(), 0, &ti) == nullptr) {
        const OrtTensorTypeAndShapeInfo* tsi = nullptr;
        (void)api->CastTypeInfoToTensorInfo(ti, &tsi);
        size_t dims = 0; (void)api->GetDimensionsCount(tsi, &dims);
        std::vector<int64_t> shape(dims); (void)api->GetDimensions(tsi, shape.data(), dims);
        ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED; (void)api->GetTensorElementType(tsi, &type);
        api->ReleaseTypeInfo(ti);
        if (type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
            for (auto& d : shape) if (d < 0) d = 1;
            if (dims == 2 && shape[1] == 1) shape[1] = 16000;  // SwiftF0 style [1, samples]
            size_t n = 1; for (auto d : shape) n *= static_cast<size_t>(d);
            std::vector<float> ones(n, 0.01f);
            std::vector<TensorOut> outs;
            auto t0 = std::chrono::steady_clock::now();
            int rc = session->run({tensor_f32(session->input_names()[0].c_str(), shape, ones.data())}, {}, outs);
            auto t1 = std::chrono::steady_clock::now();
            if (rc != KE_OK) return rc;
            if (ms_out) *ms_out = std::chrono::duration<double, std::milli>(t1 - t0).count();
        }
    }
    return KE_OK;
}

}  // namespace ke
