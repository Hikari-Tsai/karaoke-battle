#include "dsp/onset.h"

#include <algorithm>
#include <cmath>

#define POCKETFFT_NO_MULTITHREADING
#include "pocketfft/pocketfft_hdronly.h"

namespace ke::dsp {

namespace {
constexpr double kPi = 3.14159265358979323846;

int pow2_near(double v) {
    int n = 64;
    while (n * 1.5 < v) n *= 2;
    return n;
}
}  // namespace

OnsetDetector::OnsetDetector(int sample_rate)
    : sr_(sample_rate),
      n_(pow2_near(sample_rate * 0.0213)),                       // 1024 at 44.1/48 kHz
      hop_(std::max(1, static_cast<int>(std::lround(sample_rate * 0.005)))),
      lag_(2) {
    buf_.assign(n_, 0.f);
    frame_.assign(n_, 0.f);
    window_.resize(n_);
    for (int i = 0; i < n_; ++i) window_[i] = static_cast<float>(0.5 - 0.5 * std::cos(2.0 * kPi * i / n_));
    spec_.resize(n_ / 2 + 1);
    // Voice band: 80 Hz .. 8 kHz.
    bin_lo_ = std::max(1, static_cast<int>(80.0 * n_ / sr_));
    bin_hi_ = std::min(n_ / 2, static_cast<int>(8000.0 * n_ / sr_));
}

OnsetDetector::Frame OnsetDetector::analyse() {
    double energy = 0.0;
    for (int i = 0; i < n_; ++i) {
        const float v = buf_[(pos_ + i) % n_];   // oldest first
        energy += double(v) * v;
        frame_[i] = v * window_[i];
    }
    const float rms_db = static_cast<float>(20.0 * std::log10(std::max(std::sqrt(energy / n_), 1e-7)));

    const pocketfft::shape_t shape{static_cast<size_t>(n_)};
    const pocketfft::stride_t s_real{sizeof(float)}, s_cplx{sizeof(std::complex<float>)};
    pocketfft::r2c<float>(shape, s_real, s_cplx, 0, true, frame_.data(), spec_.data(), 1.f);

    const int nb = bin_hi_ - bin_lo_ + 1;
    std::vector<float> mag(nb);
    for (int k = 0; k < nb; ++k) mag[k] = std::log1p(10.f * std::abs(spec_[bin_lo_ + k]));

    // SuperFlux-style: positive difference to the max-filtered spectrum `lag_`
    // hops back, so vibrato and slow swells do not register as onsets.
    float odf = 0.f;
    if (static_cast<int>(mags_.size()) >= lag_) {
        const auto& ref = mags_.front();
        for (int k = 0; k < nb; ++k) {
            float r = ref[k];
            if (k > 0) r = std::max(r, ref[k - 1]);
            if (k + 1 < nb) r = std::max(r, ref[k + 1]);
            odf += std::max(0.f, mag[k] - r);
        }
        odf /= static_cast<float>(nb);
    }
    mags_.push_back(std::move(mag));
    while (static_cast<int>(mags_.size()) > lag_) mags_.pop_front();

    // Causal peak picking: the current value is the largest over the last
    // pre_max span and clears the recent mean by `delta`.
    const int hop_rate_max = std::max(1, static_cast<int>(std::lround(pre_max_s * sr_ / hop_)));
    const int hop_rate_avg = std::max(1, static_cast<int>(std::lround(pre_avg_s * sr_ / hop_)));
    odf_hist_.push_back(odf);
    while (static_cast<int>(odf_hist_.size()) > std::max(hop_rate_max, hop_rate_avg)) odf_hist_.pop_front();
    float mx = 0.f, sum = 0.f;
    int cnt = 0;
    for (int i = static_cast<int>(odf_hist_.size()) - 1, j = 0; i >= 0; --i, ++j) {
        if (j < hop_rate_max) mx = std::max(mx, odf_hist_[i]);
        if (j < hop_rate_avg) { sum += odf_hist_[i]; ++cnt; }
    }
    const float mean = cnt ? sum / cnt : 0.f;
    const int64_t idx = frame_index_++;
    const int combine = static_cast<int>(std::lround(combine_s * sr_ / hop_));
    const bool onset = odf > 0.f && odf >= mx && odf >= mean + delta && rms_db >= floor_db && idx - last_onset_ >= combine;
    if (onset) last_onset_ = idx;

    const int64_t centre = have_ - n_ / 2 + static_cast<int64_t>(std::lround(shift_s * sr_));
    return Frame{centre, onset, odf, rms_db};
}

}  // namespace ke::dsp
