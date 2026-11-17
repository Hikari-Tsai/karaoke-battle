#include "core/resample.h"

#include <algorithm>
#include <cmath>
#include <numeric>
#include <thread>
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

// Direct form: evaluates the kernel table for every tap (any rate pair).
void resample_direct(const std::vector<float>& in, double ratio, const Kernel& k,
                     std::vector<float>& out, size_t from, size_t to) {
    const long n_in = static_cast<long>(in.size());
    for (size_t n = from; n < to; ++n) {
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
}

// Polyphase form for a rational ratio up / down (e.g. 44.1k -> 48k is 160 / 147):
// output n sits at input position n * down / up, so only `up` distinct kernel
// phases exist. Their taps are taken from the same table once, and each output
// is a plain dot product (same result as the direct form, ~10x faster).
struct Phases {
    int taps = 0;                 // 2 * half_taps
    std::vector<float> coef;      // up * taps
    std::vector<float> sum;       // per phase, for the normalisation
};

Phases make_phases(const Kernel& k, long up) {
    Phases ph;
    ph.taps = 2 * k.half_taps;
    ph.coef.resize(static_cast<size_t>(up) * ph.taps);
    ph.sum.resize(static_cast<size_t>(up));
    for (long p = 0; p < up; ++p) {
        const double frac = static_cast<double>(p) / up;
        float s = 0.f;
        for (int j = 0; j < ph.taps; ++j) {
            const float w = k.at(static_cast<double>(j - k.half_taps + 1) - frac);
            ph.coef[static_cast<size_t>(p) * ph.taps + j] = w;
            s += w;
        }
        ph.sum[static_cast<size_t>(p)] = s;
    }
    return ph;
}

void resample_poly(const std::vector<float>& in, long up, long down, const Kernel& k, const Phases& ph,
                   std::vector<float>& out, size_t from, size_t to) {
    const long n_in = static_cast<long>(in.size());
    const float* x = in.data();
    for (size_t n = from; n < to; ++n) {
        const long long num = static_cast<long long>(n) * down;
        const long c = static_cast<long>(num / up);
        const long p = static_cast<long>(num % up);
        const float* w = ph.coef.data() + static_cast<size_t>(p) * ph.taps;
        const long first = c - k.half_taps + 1;
        if (first >= 0 && first + ph.taps <= n_in) {
            // Interior: four partial sums so the loop vectorises.
            const float* xi = x + first;
            float a0 = 0.f, a1 = 0.f, a2 = 0.f, a3 = 0.f;
            int j = 0;
            for (; j + 4 <= ph.taps; j += 4) {
                a0 += xi[j] * w[j];
                a1 += xi[j + 1] * w[j + 1];
                a2 += xi[j + 2] * w[j + 2];
                a3 += xi[j + 3] * w[j + 3];
            }
            for (; j < ph.taps; ++j) a0 += xi[j] * w[j];
            const float s = ph.sum[static_cast<size_t>(p)];
            out[n] = s != 0.f ? ((a0 + a1) + (a2 + a3)) / s : 0.f;
        } else {
            // Edges: only the taps inside the signal, normalised by their sum.
            const long j0 = std::max(0L, -first);
            const long j1 = std::min(static_cast<long>(ph.taps), n_in - first);
            float acc = 0.f, wsum = 0.f;
            for (long j = j0; j < j1; ++j) {
                acc += x[first + j] * w[j];
                wsum += w[j];
            }
            out[n] = wsum != 0.f ? acc / wsum : 0.f;
        }
    }
}

// Splits [0, n) over a few threads when the work is large enough to pay for them.
template <class F>
void parallel_ranges(size_t n, F&& body) {
    const size_t min_chunk = 1 << 16;
    unsigned hw = std::max(1u, std::thread::hardware_concurrency());
    const size_t workers = std::min<size_t>({static_cast<size_t>(hw), size_t(8), std::max<size_t>(1, n / min_chunk)});
    if (workers <= 1) {
        body(size_t(0), n);
        return;
    }
    std::vector<std::thread> pool;
    pool.reserve(workers - 1);
    const size_t step = (n + workers - 1) / workers;
    for (size_t w = 1; w < workers; ++w) {
        const size_t a = std::min(n, w * step), b = std::min(n, a + step);
        pool.emplace_back([&body, a, b] { body(a, b); });
    }
    body(size_t(0), std::min(n, step));
    for (auto& t : pool) t.join();
}
}  // namespace

std::vector<float> resample(const std::vector<float>& in, int in_rate, int out_rate) {
    if (in_rate == out_rate || in.empty() || in_rate <= 0 || out_rate <= 0) return in;
    const double ratio = double(out_rate) / in_rate;
    const size_t out_len = static_cast<size_t>(std::llround(in.size() * ratio));
    std::vector<float> out(out_len, 0.f);
    const Kernel k(ratio);
    const long g = std::gcd(in_rate, out_rate);
    const long up = out_rate / g, down = in_rate / g;
    if (up <= 4096) {
        const Phases ph = make_phases(k, up);
        parallel_ranges(out_len, [&](size_t a, size_t b) { resample_poly(in, up, down, k, ph, out, a, b); });
    } else {
        parallel_ranges(out_len, [&](size_t a, size_t b) { resample_direct(in, ratio, k, out, a, b); });
    }
    return out;
}

}  // namespace ke
