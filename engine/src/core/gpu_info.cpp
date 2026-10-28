#include "core/gpu_info.h"

#include "nlohmann/json.hpp"

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#  include <dxgi.h>
#elif defined(__APPLE__)
#  include <sys/sysctl.h>
#else
#  include <dlfcn.h>
#endif

namespace ke {

namespace {

#if !defined(__APPLE__)
// Query the NVIDIA driver through the CUDA driver API (nvcuda.dll / libcuda.so)
// without linking against it. Fills driver version and compute capability.
void query_cuda(nlohmann::json& gpu, int ordinal) {
    using cuInit_t = int (*)(unsigned);
    using cuDriverGetVersion_t = int (*)(int*);
    using cuDeviceGetCount_t = int (*)(int*);
    using cuDeviceGetAttribute_t = int (*)(int*, int, int);
    using cuDeviceTotalMem_t = int (*)(size_t*, int);
    using cuDeviceGetName_t = int (*)(char*, int, int);
#if defined(_WIN32)
    HMODULE h = LoadLibraryA("nvcuda.dll");
    if (!h) return;
    auto load = [&](const char* n) { return reinterpret_cast<void*>(GetProcAddress(h, n)); };
#else
    void* h = dlopen("libcuda.so.1", RTLD_NOW);
    if (!h) return;
    auto load = [&](const char* n) { return dlsym(h, n); };
#endif
    auto cuInit = reinterpret_cast<cuInit_t>(load("cuInit"));
    auto cuDriverGetVersion = reinterpret_cast<cuDriverGetVersion_t>(load("cuDriverGetVersion"));
    auto cuDeviceGetCount = reinterpret_cast<cuDeviceGetCount_t>(load("cuDeviceGetCount"));
    auto cuDeviceGetAttribute = reinterpret_cast<cuDeviceGetAttribute_t>(load("cuDeviceGetAttribute"));
    auto cuDeviceTotalMem = reinterpret_cast<cuDeviceTotalMem_t>(load("cuDeviceTotalMem_v2"));
    auto cuDeviceGetName = reinterpret_cast<cuDeviceGetName_t>(load("cuDeviceGetName"));
    if (!cuInit || !cuDriverGetVersion || !cuDeviceGetCount || !cuDeviceGetAttribute) return;
    if (cuInit(0) != 0) return;
    int ver = 0; cuDriverGetVersion(&ver);
    gpu["cuda_driver_version"] = ver;   // e.g. 12080 = CUDA 12.8
    int count = 0; cuDeviceGetCount(&count);
    if (ordinal < count) {
        int major = 0, minor = 0;
        cuDeviceGetAttribute(&major, 75 /*CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR*/, ordinal);
        cuDeviceGetAttribute(&minor, 76 /*CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR*/, ordinal);
        gpu["compute_capability"] = std::to_string(major) + "." + std::to_string(minor);
        gpu["cuda_device_index"] = ordinal;
        if (cuDeviceTotalMem) { size_t mem = 0; cuDeviceTotalMem(&mem, ordinal); gpu["vram_mb"] = static_cast<int64_t>(mem / (1024 * 1024)); }
        if (cuDeviceGetName && !gpu.contains("name")) { char name[256] = {0}; cuDeviceGetName(name, 255, ordinal); gpu["name"] = name; }
    }
}
#endif

}  // namespace

std::string gpu_info_json() {
    nlohmann::json arr = nlohmann::json::array();
#if defined(_WIN32)
    IDXGIFactory* factory = nullptr;
    if (SUCCEEDED(CreateDXGIFactory(__uuidof(IDXGIFactory), reinterpret_cast<void**>(&factory)))) {
        IDXGIAdapter* adapter = nullptr;
        int nvidia_ordinal = 0;
        for (UINT i = 0; factory->EnumAdapters(i, &adapter) != DXGI_ERROR_NOT_FOUND; ++i) {
            DXGI_ADAPTER_DESC desc;
            if (SUCCEEDED(adapter->GetDesc(&desc))) {
                nlohmann::json g;
                char name[256];
                WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, sizeof(name), nullptr, nullptr);
                g["name"] = name;
                g["adapter_index"] = i;
                g["vram_mb"] = static_cast<int64_t>(desc.DedicatedVideoMemory / (1024 * 1024));
                const char* vendor = "other";
                switch (desc.VendorId) {
                    case 0x10DE: vendor = "nvidia"; break;
                    case 0x1002: vendor = "amd"; break;
                    case 0x8086: vendor = "intel"; break;
                    case 0x1414: vendor = "microsoft"; break;  // Basic Render Driver
                }
                g["vendor"] = vendor;
                g["software"] = desc.VendorId == 0x1414;
                if (desc.VendorId == 0x10DE) query_cuda(g, nvidia_ordinal++);
                arr.push_back(g);
            }
            adapter->Release();
        }
        factory->Release();
    }
#elif defined(__APPLE__)
    nlohmann::json g;
    char model[256] = {0};
    size_t len = sizeof(model);
    sysctlbyname("machdep.cpu.brand_string", model, &len, nullptr, 0);
    g["name"] = model;
    g["vendor"] = "apple";
    g["adapter_index"] = 0;
    int64_t mem = 0; len = sizeof(mem);
    sysctlbyname("hw.memsize", &mem, &len, nullptr, 0);
    g["vram_mb"] = mem / (1024 * 1024);  // unified memory
    arr.push_back(g);
#else
    nlohmann::json g;
    g["name"] = "unknown"; g["vendor"] = "other"; g["adapter_index"] = 0;
    query_cuda(g, 0);
    if (g.contains("cuda_driver_version")) g["vendor"] = "nvidia";
    arr.push_back(g);
#endif
    return arr.dump();
}

}  // namespace ke
