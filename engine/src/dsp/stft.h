// STFT / ISTFT built on pocketfft (mixed radix, so n_fft like 7680 or 5120 are fine).
#pragma once
#include <complex>
#include <vector>

namespace ke::dsp {

enum class Window { Hann, HannPeriodic };

class Stft {
public:
    // center=true pads n_fft/2 reflectively on both sides (torch.stft default, used by UVR).
    Stft(int n_fft, int hop, Window window = Window::HannPeriodic, bool center = true);

    int n_fft() const { return n_fft_; }
    int hop() const { return hop_; }
    int n_bins() const { return n_fft_ / 2 + 1; }
    // Number of frames produced for `samples` input samples.
    size_t num_frames(size_t samples) const;

    // out layout: frames x bins (row-major), complex<float>
    void forward(const float* x, size_t n, std::vector<std::complex<float>>& out) const;
    // inverse with overlap-add and window-sum normalisation; `out` gets `length` samples.
    void inverse(const std::complex<float>* spec, size_t frames, size_t length, std::vector<float>& out) const;

private:
    int n_fft_, hop_;
    bool center_;
    std::vector<float> window_;
};

}  // namespace ke::dsp
