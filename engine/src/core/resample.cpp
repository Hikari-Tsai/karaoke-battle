#include "core/resample.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace ke {

namespace {
constexpr double kPi = 3.14159265358979323846;

// Windowed-sinc kernel sampled on a fine grid so the per-sample loop only
// does table lookups + linear interpolation (no transcendental calls).
struct Kernel {
    int half_taps = 0;          // taps per side in input samples
    int phases = 0;             // table resolution per input sample
    std::vector<float> table;   // (2*half_taps*phases + 1) entries over x in [-half_taps, half_taps]

    Kernel(double ratio) {
        const double scale = std::min(1.0, ratio);          // < 1 when downsampling: wider kernel
        const double cutoff = 0.95 * scale * 0.5;           // cycles per input sample
        const int half_width = 32;                          // taps per side at the slower rate
        half_taps = static_cast<int>(std::ceil(half_width / scale));
        phases = 128;
        const int n = 2 * half_taps * phases + 1;
        table.resize(n);
        for (int i = 0; i < n; ++i) {
            const double x = static_cast<double>(i) / phases - half_taps;   // input samples
            double s = (std::abs(x) < 1e-9) ? 2.0 * cutoff : std::sin(2.0 * kPi * cutoff * x) / (kPi * x);
            const double u = x * scale / half_width;                        // [-1, 1]
            double w = 0.0;
            if (u > -1.0 && u < 1.0) w = 0.42 + 0.5 * std::cos(kPi * u) + 0.08 * std::cos(2.0 * kPi * u);
            table[i] = static_cast<float>(s * w);
        }
    }

    inline float at(double x) const {   // x in [-half_taps, half_taps]
        const double pos = (x + half_taps) * phases;
        const int i = static_cast<int>(pos);
        if (i < 0 || i + 1 >= static_cast<int>(table.size())) return 0.f;
        const float frac = static_cast<float>(pos - i);
        return table[i] + (table[i + 1] - table[i]) * frac;
    }
};
}  // namespace

std::vector<float> resample(const std::vector<float>& in, int in_rate, int out_rate) {
    if (in_rate == out_rate || in.empty() || in_rate <= 0 || out_rate <= 0) return in;
    const double ratio = double(out_rate) / in_rate;
    const size_t out_len = static_cast<size_t>(std::llround(in.size() * ratio));
    std::vector<float> out(out_len, 0.f);
    const Kernel k(ratio);
    const long n_in = static_cast<long>(in.size());

    for (size_t n = 0; n < out_len; ++n) {
        const double center = n / ratio;
        const long c = static_cast<long>(std::floor(center));
        const long i0 = std::max(0L, c - k.half_taps + 1);
        const long i1 = std::min(n_in - 1, c + k.half_taps);
        float acc = 0.f, wsum = 0.f;
        for (long i = i0; i <= i1; ++i) {
            const float w = k.at(static_cast<double>(i) - center);
            acc += in[static_cast<size_t>(i)] * w;
            wsum += w;
        }
        // Normalising by the kernel sum keeps DC gain at exactly 1 and handles the edges.
        out[n] = wsum != 0.f ? acc / wsum : 0.f;
    }
    return out;
}

}  // namespace ke
