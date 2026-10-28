#include "dsp/stft.h"

#include <cmath>

#define POCKETFFT_NO_MULTITHREADING
#include "pocketfft/pocketfft_hdronly.h"

namespace ke::dsp {

namespace {
constexpr double kPi = 3.14159265358979323846;
}

Stft::Stft(int n_fft, int hop, Window window, bool center) : n_fft_(n_fft), hop_(hop), center_(center) {
    window_.resize(n_fft);
    const int denom = window == Window::HannPeriodic ? n_fft : (n_fft - 1);
    for (int i = 0; i < n_fft; ++i) window_[i] = static_cast<float>(0.5 - 0.5 * std::cos(2.0 * kPi * i / denom));
}

size_t Stft::num_frames(size_t samples) const {
    const size_t padded = center_ ? samples + static_cast<size_t>(n_fft_) : samples;
    if (padded < static_cast<size_t>(n_fft_)) return 0;
    return 1 + (padded - n_fft_) / hop_;
}

void Stft::forward(const float* x, size_t n, std::vector<std::complex<float>>& out) const {
    const size_t pad = center_ ? n_fft_ / 2 : 0;
    std::vector<float> padded(n + 2 * pad);
    for (size_t i = 0; i < n; ++i) padded[pad + i] = x[i];
    if (center_) {  // reflect padding like torch.stft(pad_mode="reflect")
        for (size_t i = 0; i < pad; ++i) {
            padded[pad - 1 - i] = n > i + 1 ? x[i + 1] : 0.f;
            padded[pad + n + i] = n > i + 1 ? x[n - 2 - i] : 0.f;
        }
    }
    const size_t frames = num_frames(n);
    const size_t bins = n_bins();
    out.assign(frames * bins, {0.f, 0.f});
    std::vector<float> frame(n_fft_);
    std::vector<std::complex<float>> spec(bins);
    pocketfft::shape_t shape{static_cast<size_t>(n_fft_)};
    pocketfft::stride_t sin{sizeof(float)}, sout{sizeof(std::complex<float>)};
    for (size_t f = 0; f < frames; ++f) {
        const size_t start = f * hop_;
        for (int i = 0; i < n_fft_; ++i) frame[i] = padded[start + i] * window_[i];
        pocketfft::r2c<float>(shape, sin, sout, 0, true, frame.data(), spec.data(), 1.f);
        for (size_t b = 0; b < bins; ++b) out[f * bins + b] = spec[b];
    }
}

void Stft::inverse(const std::complex<float>* spec, size_t frames, size_t length, std::vector<float>& out) const {
    const size_t pad = center_ ? n_fft_ / 2 : 0;
    const size_t total = (frames ? (frames - 1) * hop_ + n_fft_ : 0);
    std::vector<float> acc(total, 0.f), wsum(total, 0.f);
    const size_t bins = n_bins();
    std::vector<std::complex<float>> in(bins);
    std::vector<float> frame(n_fft_);
    pocketfft::shape_t shape{static_cast<size_t>(n_fft_)};
    pocketfft::stride_t sin{sizeof(std::complex<float>)}, sout{sizeof(float)};
    const float scale = 1.0f / n_fft_;
    for (size_t f = 0; f < frames; ++f) {
        for (size_t b = 0; b < bins; ++b) in[b] = spec[f * bins + b];
        pocketfft::c2r<float>(shape, sin, sout, 0, false, in.data(), frame.data(), scale);
        const size_t start = f * hop_;
        for (int i = 0; i < n_fft_; ++i) {
            acc[start + i] += frame[i] * window_[i];
            wsum[start + i] += window_[i] * window_[i];
        }
    }
    out.assign(length, 0.f);
    for (size_t i = 0; i < length; ++i) {
        const size_t j = i + pad;
        if (j < total && wsum[j] > 1e-8f) out[i] = acc[j] / wsum[j];
    }
}

}  // namespace ke::dsp
