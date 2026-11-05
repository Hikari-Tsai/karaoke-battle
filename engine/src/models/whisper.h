// Whisper (OpenAI) speech recognition with the onnx-community export of
// whisper-large-v3: encoder_model.onnx + decoder_model_merged.onnx (KV cache,
// external .onnx_data). Used to recognise song lyrics from the separated
// vocal stem and to time lyrics the user pasted.
//
//   16 kHz mono -> 30 s windows -> log-mel (n_fft 400, hop 160, 128 Slaney
//   mel bands, log10, max-8 clamp, (x+4)/4; as WhisperFeatureExtractor)
//   -> encoder -> greedy decoding with the reference timestamp rules
//   (paired timestamps, monotonic, max initial timestamp, timestamp
//   probability rule, suppressed and begin-suppressed tokens)
//   -> segments; long-form seeking as in openai/whisper transcribe().
//
// Token ids are model specific and read from generation_config.json; text
// is decoded by the caller (the app has the tokenizer).
#pragma once
#include <cstdint>
#include <string>
#include <vector>
#include "karaoke_engine.h"

namespace ke::whisper {

constexpr int kSampleRate = 16000;
constexpr int kNfft = 400;
constexpr int kHop = 160;
constexpr int kMels = 128;
constexpr int kWindowFrames = 3000;           // 30 s of mel frames
constexpr int kWindowSamples = kWindowFrames * kHop;

struct Segment {
    double start = 0, end = 0;                // seconds from the file start
    std::vector<int64_t> tokens;              // text tokens only
    double avg_logprob = 0;
};

// Slaney mel filter bank, kMels x (kNfft / 2 + 1), row-major
// (transformers mel_filter_bank(norm="slaney", mel_scale="slaney")).
std::vector<float> mel_filters();

// Log-mel features of one window: `n` samples (<= kWindowSamples, zero
// padded to 30 s) -> kMels x kWindowFrames, row-major.
void log_mel(const float* samples, size_t n, const std::vector<float>& filters, std::vector<float>& out);

// Singing activity per 10 ms frame of the 16 kHz vocal stem: frames within
// `hold` frames of one louder than (95th percentile - range_db). Relative
// to the loud part of the stem, so instrument bleed in a separated stem's
// intro does not count (Whisper invents text such as credits there).
std::vector<uint8_t> voiced_frames(const std::vector<float>& audio, double range_db = 22.0, int hold = 30);

// Long-form recognition of a WAV. options_json:
//   {"language_token":50260, "task_token":50360,
//    "prompt_tokens":[...],          // style prompt, before every window
//    "condition_on_previous":true,   // + the previous windows' tokens "no_speech_threshold":0.6,
//    "logprob_threshold":-1.0}
// Output JSON: {"segments":[{"start":s,"end":s,"avg_logprob":x,"tokens":[...]}],
//               "windows":n,"duration":s}
int recognize_file(ke_runtime* rt, const std::string& model_dir, const std::string& input_wav,
                   const std::string& options_json, const std::string& out_json,
                   ke_progress_cb progress, void* user);

}  // namespace ke::whisper
