// Low-latency onset detector for the live judgements: log-magnitude spectral
// flux on short windows (~21 ms, hop ~5 ms) with causal peak picking, so an
// onset is reported about one window after the sound, without waiting for a
// pitch estimate. Runs on the capture worker (pocketfft allocates scratch).
#pragma once
#include <complex>
#include <cstdint>
#include <deque>
#include <vector>

namespace ke::dsp {

class OnsetDetector {
public:
    struct Frame {
        int64_t centre;   // sample index of the onset (window centre + shift)
        bool onset;       // an onset is reported at this frame
        float odf;        // onset detection function value (spectral flux)
        float rms_db;     // level of the window
    };

    explicit OnsetDetector(int sample_rate);

    int window() const { return n_; }
    int hop() const { return hop_; }

    // Feeds samples; calls emit(Frame) once per hop.
    template <class F>
    void feed(const float* x, size_t n, F&& emit) {
        for (size_t i = 0; i < n; ++i) {
            buf_[pos_] = x[i];
            pos_ = (pos_ + 1) % n_;
            ++have_;
            if (have_ >= n_ && (have_ - n_) % hop_ == 0) emit(analyse());
        }
    }

    // Tunables (exposed for the evaluation tool).
    float delta = 0.06f;          // threshold above the recent mean
    float floor_db = -50.f;       // ignore onsets quieter than this
    double combine_s = 0.06;      // minimum gap between onsets
    double pre_max_s = 0.03;      // ODF must be the max over this past span
    double pre_avg_s = 0.10;      // mean taken over this past span
    // Added to the reported time. On separated vocals the detected onsets sit
    // ~24 ms before GAME's note onsets (the consonant comes before the stable
    // pitch the notes start at), so the singer is not judged FAST for it.
    double shift_s = 0.024;

private:
    Frame analyse();

    int sr_, n_, hop_, lag_;
    int bin_lo_, bin_hi_;
    std::vector<float> buf_, window_, frame_;
    size_t pos_ = 0;
    int64_t have_ = 0;
    std::vector<std::complex<float>> spec_;
    std::deque<std::vector<float>> mags_;   // last `lag_` log spectra
    std::deque<float> odf_hist_;
    int64_t last_onset_ = INT64_MIN / 2;
    int64_t frame_index_ = 0;
};

}  // namespace ke::dsp
