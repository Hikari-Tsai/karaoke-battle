// Dynamically loaded ONNX Runtime + small C++ helpers around the C API.
//
// The engine never links against onnxruntime. The app tells us which
// library to load (CPU/DirectML/CUDA builds have different DLL sets) and
// which execution provider to use. All model code goes through OrtSession
// below so EP handling and error translation live in one place.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "onnxruntime_c_api.h"
#include "karaoke_engine.h"

struct ke_runtime {
    void* lib_handle = nullptr;        // dlopen / LoadLibrary handle
    const OrtApiBase* api_base = nullptr;
    const OrtApi* api = nullptr;       // API struct for ORT_API_VERSION of the headers we compiled with
    std::string ort_version;
    std::string lib_path;
    std::string lib_dir;
    OrtEnv* env = nullptr;
    int requested_ep = KE_EP_CPU;
    int active_ep = KE_EP_CPU;
    int device_id = 0;
    int num_threads = 0;
    std::string ep_error;              // why the requested EP was not used (if any)
};

namespace ke {

// --- tensor description used by OrtSession::run ---------------------------
struct TensorView {
    const char* name = nullptr;
    ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
    std::vector<int64_t> shape;
    const void* data = nullptr;        // host memory, row-major
    size_t bytes = 0;
};

struct TensorOut {
    std::string name;
    ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
    std::vector<int64_t> shape;
    std::vector<uint8_t> data;         // raw bytes copied out of ORT
    size_t count() const;              // number of elements
    const float* f32() const { return reinterpret_cast<const float*>(data.data()); }
    const double* f64() const { return reinterpret_cast<const double*>(data.data()); }
    const int64_t* i64() const { return reinterpret_cast<const int64_t*>(data.data()); }
    const bool* b() const { return reinterpret_cast<const bool*>(data.data()); }
};

// Convenience constructors.
TensorView tensor_f32(const char* name, std::vector<int64_t> shape, const float* data);
TensorView tensor_f32_scalar(const char* name, const float* value);
TensorView tensor_i64(const char* name, std::vector<int64_t> shape, const int64_t* data);
TensorView tensor_i64_scalar(const char* name, const int64_t* value);
TensorView tensor_bool(const char* name, std::vector<int64_t> shape, const bool* data);

// --- session -----------------------------------------------------------------
class OrtSession {
public:
    // Creates a session on rt's EP. Falls back to CPU (and records rt->ep_error)
    // if the EP refuses the model. Returns nullptr and sets ke_last_error on failure.
    static std::unique_ptr<OrtSession> create(ke_runtime* rt, const std::string& model_path,
                                              std::string* error);
    ~OrtSession();

    // Runs the graph. Output names may be empty to fetch every output.
    // Returns KE_OK or KE_ERR_ORT (ke_last_error set).
    int run(const std::vector<TensorView>& inputs, const std::vector<std::string>& output_names,
            std::vector<TensorOut>& outputs);

    const std::vector<std::string>& input_names() const { return input_names_; }
    const std::vector<std::string>& output_names() const { return output_names_; }
    bool has_input(const std::string& n) const;
    ::OrtSession* raw() const { return raw_; }

private:
    OrtSession() = default;
    ke_runtime* rt_ = nullptr;
    OrtSession* session_ = nullptr;
    OrtMemoryInfo* mem_ = nullptr;
    std::vector<std::string> input_names_;
    std::vector<std::string> output_names_;
    friend class OrtSessionBuilder;
    ::OrtSession* raw_ = nullptr;
};

// Internal helpers used by api.cpp
int runtime_create(const char* ort_library_path, int ep, int device_id, int num_threads, ke_runtime** out);
void runtime_destroy(ke_runtime* rt);
int runtime_selftest(ke_runtime* rt, const char* model_path_or_null, double* ms_out);
std::string runtime_info_json(const ke_runtime* rt);
const char* ep_name(int ep);

}  // namespace ke
