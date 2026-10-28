// Port of GAME's inference/slicer2.py (silence based audio slicer).
//
// The behaviour matches slicer2.py exactly: same RMS framing (librosa style
// framing with constant zero padding of frame_length // 2 on both sides),
// same hop / window sizes (Python round-half-to-even), same silence tag
// logic, same trailing silence handling and the same _apply_slice clamping.
#pragma once
#include <cstddef>
#include <string>
#include <vector>

namespace ke::game {

struct Slice {
    size_t begin = 0;   // sample index into the source waveform (inclusive)
    size_t end = 0;     // exclusive
    size_t length() const { return end > begin ? end - begin : 0; }
};

struct SlicerParams {
    int sr = 44100;
    float threshold_db = -40.f;
    int min_length_ms = 1000;
    int min_interval_ms = 200;
    int hop_ms = 20;
    int max_sil_kept_ms = 100;
};

// Resolved frame-level parameters, computed exactly like Slicer.__init__.
struct SlicerFrames {
    int hop_size = 0;       // samples
    int win_size = 0;       // samples (RMS frame length)
    int min_length = 0;     // frames
    int min_interval = 0;   // frames
    int max_sil_kept = 0;   // frames
    double threshold = 0;   // linear amplitude
};

// Python round(): round half to even.
long long py_round(double x);

// Validates the constraints Slicer.__init__ raises on. Returns false and fills
// `why` when they are violated.
bool validate_slicer_params(const SlicerParams& p, std::string* why);
SlicerFrames resolve_slicer_frames(const SlicerParams& p);

// librosa-style RMS per frame: pad frame_length//2 zeros on both sides, frames
// of `frame_length` samples every `hop_length` samples, sqrt(mean(x^2)).
// Frame i is centred on sample i * hop_length of the unpadded signal.
std::vector<float> get_rms(const std::vector<float>& y, int frame_length, int hop_length);

// Returns slices covering the voiced parts of `mono` in order (never empty for
// a non-empty input). Empty slices are dropped. Behaviour matches
// Slicer.slice(); the offset of a slice is begin / sr.
std::vector<Slice> slice_waveform(const std::vector<float>& mono, const SlicerParams& p);

// Additionally splits every slice longer than `max_samples` at its quietest RMS
// frame (RMS framing from `frames`, search restricted to the central half of
// the slice so both parts shrink), recursively, until all pieces fit.
// `rms` may be empty; it is then computed on demand with get_rms().
std::vector<Slice> split_long_slices(const std::vector<float>& mono, const std::vector<Slice>& slices,
                                     const SlicerFrames& frames, size_t max_samples,
                                     std::vector<float>* rms_cache = nullptr);

}  // namespace ke::game
