// SwiftF0 pitch estimator (ONNX, 16 kHz, 16 ms hop). See docs/ARCHITECTURE.md §SwiftF0.
// Numerically replicates the swift-f0 0.3.0 Python package (framing, silence gate,
// windowing with left context / lookahead, loudness).
#pragma once
#include <memory>
#include <string>
#include <vector>
#include "karaoke_engine.h"

namespace ke {
class OrtSession;
}

namespace ke::swiftf0 {

constexpr int kSampleRate = 16000;
constexpr int kHop = 256;             // 16 ms
constexpr float kFminDefault = 46.875f;
constexpr float kFmaxDefault = 2093.75f;
constexpr float kVoicedThreshold = 0.5f;
// Ratio between two of the model's 95 log-spaced pitch bins (fmax must be >= fmin * ratio).
constexpr float kBinRatio = 1.0412009f;   // (2093.75 / 46.875) ** (1 / 94)
// Receptive field: a frame is final once 10 later frames exist, and 11 earlier
// frames reproduce the whole-file result (swift-f0 LOOKAHEAD_FRAMES / LEFT_FRAMES).
constexpr size_t kLookaheadFrames = 10;
constexpr size_t kLeftFrames = 11;
constexpr size_t kWindowFrames = 1875;    // 30 s per model call for long files

// Clamps fmin/fmax into the model range the way swift-f0 does.
void clamp_range(float& fmin, float& fmax);
// swift-f0 loudness: RMS dB of the 512 samples centred on `frame` (prev hop + own hop).
float loudness_db(const float* audio16k, size_t n, size_t frame);

class Model {
public:
    static std::unique_ptr<Model> load(ke_runtime* rt, const std::string& model_path, std::string* error);
    ~Model();
    // audio16k: mono float at 16 kHz, any length. Fills f0 (Hz, raw model pitch) and
    // confidence per frame (frames = max(1, n / 256)); callers treat confidence < 0.5
    // as unvoiced. Long input is windowed and stitched exactly like swift-f0.
    int run(const float* audio16k, size_t n, float fmin, float fmax,
            std::vector<float>& f0, std::vector<float>& confidence);
    int run(const float* audio16k, size_t n, float fmin, float fmax,
            std::vector<float>& f0, std::vector<float>& confidence, ke_progress_cb progress, void* user);
    // One raw model call (no windowing). Used by the live path, which supplies its own context.
    int run_window(const float* audio16k, size_t n, float fmin, float fmax,
                   std::vector<float>& f0, std::vector<float>& confidence);
private:
    Model() = default;
    std::unique_ptr<OrtSession> session_;
};

// Offline: WAV -> JSON (see ke_f0_extract).
int extract_file(ke_runtime* rt, const std::string& model_path, const std::string& input_wav,
                 float fmin, float fmax, const std::string& out_json, ke_progress_cb progress, void* user);

}  // namespace ke::swiftf0
