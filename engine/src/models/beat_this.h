// Beat This! (CPJKU, ISMIR 2024) beat / downbeat tracking, ONNX final0
// checkpoint. Replicates the reference pipeline used by the Key & Tempo app
// (Hikari-Tsai/music-detection frontend/inference/dsp.js + tempo.js), which
// itself matches the beat_this Python package:
//   22.05 kHz mono -> periodic Hann STFT (n_fft 1024, hop 441, reflect pad,
//   magnitude / sqrt(n_fft)) -> 128 Slaney mel filters (frontend.json)
//   -> log1p(1000 x) -> 1500-frame chunks with 6-frame borders -> logits
//   -> peak picking (logit > 0, max over +-3 frames, running-mean merge)
//   -> downbeats snapped to the nearest beat -> tempo grid fit.
#pragma once
#include <string>
#include <vector>
#include "karaoke_engine.h"

namespace ke::beat_this {

constexpr int kSampleRate = 22050;
constexpr int kFps = 50;          // 22050 / 441
constexpr int kChunk = 1500;
constexpr int kBorder = 6;

struct Result {
    std::vector<double> beats;      // seconds
    std::vector<double> downbeats;  // seconds, each equal to a beat
    double bpm = -1;                // < 0 when unavailable
    int signature_beats = 0;        // beats per bar, 0 = unknown
    std::string tempo_mode = "unavailable";  // constant | variable | average | unavailable
};

// Pure helpers (exposed for tests).
std::vector<double> pick_peaks(const std::vector<float>& logits);
void postprocess(const std::vector<float>& beat, const std::vector<float>& downbeat, Result& out);
void estimate_tempo(Result& r);
std::vector<long> chunk_starts(long frames);

// Offline: WAV -> beats JSON (see ke_beats).
int extract_file(ke_runtime* rt, const std::string& model_dir, const std::string& input_wav,
                 const std::string& out_json, ke_progress_cb progress, void* user);

}  // namespace ke::beat_this
