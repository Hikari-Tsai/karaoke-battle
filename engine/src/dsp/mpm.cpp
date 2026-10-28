#include "dsp/mpm.h"

#include <algorithm>
#include <cmath>

#include "pocketfft/pocketfft_hdronly.h"

namespace ke::dsp {

Mpm::Mpm(int sample_rate, int window, float fmin, float fmax)
    : sr_(sample_rate), window_(window), fmin_(fmin), fmax_(fmax), nsdf_(window, 0.f) {
    // Autocorrelation through a zero-padded FFT (linear, not circular): O(N log N)
    // instead of O(N * tau_max); ~0.2 ms for a 2048 window instead of 2-4 ms.
    fft_n_ = 1;
    while (fft_n_ < 2 * window) fft_n_ <<= 1;
    padded_.assign(static_cast<size_t>(fft_n_), 0.f);
    spec_.assign(static_cast<size_t>(fft_n_ / 2 + 1), std::complex<float>(0.f, 0.f));
    peaks_.reserve(static_cast<size_t>(window) / 2 + 1);   // one peak per positive lobe at most
}

float Mpm::detect(const float* x, float* clarity) {
    const int W = window_;
    const int tau_min = std::max(2, static_cast<int>(sr_ / fmax_));
    const int tau_max = std::min(W - 2, static_cast<int>(sr_ / fmin_));
    if (clarity) *clarity = 0.f;
    if (tau_max <= tau_min) return 0.f;

    double total = 0.0;
    for (int i = 0; i < W; ++i) total += double(x[i]) * x[i];
    if (total <= 1e-12) return 0.f;   // digital silence

    // acf[tau] = sum_i x[i] x[i+tau] via FFT of the zero-padded window.
    std::copy(x, x + W, padded_.begin());
    std::fill(padded_.begin() + W, padded_.end(), 0.f);
    const pocketfft::shape_t shape{static_cast<size_t>(fft_n_)};
    const pocketfft::stride_t s_real{sizeof(float)}, s_cplx{sizeof(std::complex<float>)};
    pocketfft::r2c<float>(shape, s_real, s_cplx, 0, true, padded_.data(), spec_.data(), 1.f);
    for (auto& c : spec_) c = std::complex<float>(std::norm(c), 0.f);
    pocketfft::c2r<float>(shape, s_cplx, s_real, 0, false, spec_.data(), padded_.data(), 1.f / static_cast<float>(fft_n_));

    // NSDF: m(tau) = sum_{i<W-tau} x[i]^2 + x[i+tau]^2 = (total - tail(tau)) + (total - head(tau)).
    double head = 0.0;   // sum of x[i]^2 for i < tau
    double tail = 0.0;   // sum of x[i]^2 for i >= W - tau
    for (int tau = 0; tau <= tau_max; ++tau) {
        const double m = (total - tail) + (total - head);
        nsdf_[tau] = m > 0 ? static_cast<float>(2.0 * padded_[tau] / m) : 0.f;
        head += double(x[tau]) * x[tau];
        tail += double(x[W - 1 - tau]) * x[W - 1 - tau];
    }
    // Peak picking (McLeod): skip the zero-lag lobe, then the maximum of every positive lobe.
    peaks_.clear();
    int tau = tau_min;
    while (tau < tau_max && nsdf_[tau] > 0) ++tau;        // skip the initial lobe
    while (tau < tau_max) {
        while (tau < tau_max && nsdf_[tau] <= 0) ++tau;    // negative region
        int max_pos = -1; float max_val = 0.f;
        while (tau < tau_max && nsdf_[tau] > 0) {          // positive lobe
            if (nsdf_[tau] > max_val) { max_val = nsdf_[tau]; max_pos = tau; }
            ++tau;
        }
        if (max_pos > 0) peaks_.emplace_back(max_pos, max_val);
    }
    if (peaks_.empty()) return 0.f;
    float highest = 0.f;
    for (auto& p : peaks_) highest = std::max(highest, p.second);
    const float threshold = 0.8f * highest;
    int best_tau = -1;
    float best_val = 0.f;
    for (auto& p : peaks_) {
        if (p.second >= threshold) { best_tau = p.first; best_val = p.second; break; }
    }
    if (best_tau <= 0) return 0.f;
    // Parabolic interpolation around the chosen peak.
    float refined = static_cast<float>(best_tau);
    if (best_tau + 1 <= tau_max) {
        const float a = nsdf_[best_tau - 1], b = nsdf_[best_tau], c = nsdf_[best_tau + 1];
        const float denom = a - 2 * b + c;
        if (std::abs(denom) > 1e-9f) refined += 0.5f * (a - c) / denom;
    }
    if (clarity) *clarity = std::clamp(best_val, 0.f, 1.f);
    return static_cast<float>(sr_) / refined;
}

}  // namespace ke::dsp
