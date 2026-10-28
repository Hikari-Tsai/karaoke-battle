// UVR MDX-Net source separation (ONNX). See docs/ARCHITECTURE.md §MDX.
//
// Faithful port of audio-separator's MDXSeparator.demix() (itself a port of
// UVR's SeperateMDX): the 44.1 kHz stereo mixture is padded with n_fft/2
// zeros in front, cut into chunks of hop*(2^dim_t_log2 - 1) samples that
// advance by (1-overlap)*chunk samples, every chunk is STFT'ed on its own
// (torch.stft semantics, centre/reflect), the first dim_f bins are fed to the
// model as [B, 4, dim_f, 2^dim_t_log2] = [L.re, L.im, R.re, R.im], the output
// is zero-padded back to n_fft/2+1 bins, ISTFT'ed, crossfaded with a
// symmetric Hann window and normalised by the window sum.
#pragma once
#include <string>
#include "karaoke_engine.h"

namespace ke::mdx {

struct Params {
    int n_fft = 7680;
    int hop_length = 1024;
    int dim_f = 3072;
    int dim_t_log2 = 8;          // frames per chunk = 2^dim_t_log2 = 256
    float compensate = 1.0f;
    std::string primary_stem = "Vocals";
    float overlap = 0.25f;       // fraction of chunk overlapped (audio-separator default)
    int batch_size = 1;          // chunks per ONNX run (no effect on the result)
};

// Parses the ke_separate params JSON (missing keys keep the defaults above).
// Returns KE_OK or KE_ERR_INVALID_ARG (ke_last_error set).
int parse_params(const std::string& json, Params& out);

// Full pipeline: read WAV -> 44.1k stereo -> chunked STFT -> model -> ISTFT -> write stems.
// primary_out_wav receives the model output unscaled, secondary_out_wav receives
// mixture - primary * compensate. Either path may be empty.
int separate(ke_runtime* rt, const std::string& model_path, const std::string& params_json,
             const std::string& input_wav, const std::string& primary_out_wav,
             const std::string& secondary_out_wav, ke_progress_cb progress, void* user);

}  // namespace ke::mdx
