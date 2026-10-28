// McLeod Pitch Method (MPM) for low-latency monophonic pitch tracking in the
// capture worker. No allocation in detect() after construction (apart from
// pocketfft's internal scratch, which is why it runs on a worker thread, not in
// the device callback).
#pragma once
#include <complex>
#include <utility>
#include <vector>

namespace ke::dsp {

class Mpm {
public:
    // window: analysis size in samples (2048 at 44.1/48 kHz ≈ 43 ms).
    Mpm(int sample_rate, int window = 2048, float fmin = 60.f, float fmax = 1500.f);
    // Returns f0 in Hz (0 if unvoiced) and sets `clarity` (0..1).
    // x must hold window() samples.
    float detect(const float* x, float* clarity);
    int window() const { return window_; }
    int sample_rate() const { return sr_; }
private:
    int sr_, window_;
    float fmin_, fmax_;
    int fft_n_ = 0;
    std::vector<float> nsdf_;
    std::vector<float> padded_;                   // zero-padded window / autocorrelation
    std::vector<std::complex<float>> spec_;
    std::vector<std::pair<int, float>> peaks_;    // reserved up front
};

}  // namespace ke::dsp
