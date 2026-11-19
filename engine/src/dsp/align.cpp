#include "dsp/align.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdio>
#include <numeric>

#include "pocketfft/pocketfft_hdronly.h"

namespace ke::align {

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr int kHop = 80;        // envelope frame: 10 ms at 8 kHz
constexpr int kEnvFft = 512;

using cvec = std::vector<std::complex<float>>;

void rfft(const std::vector<float>& x, size_t n, cvec& out) {
    std::vector<float> in(n, 0.f);
    std::copy_n(x.begin(), std::min(n, x.size()), in.begin());
    out.assign(n / 2 + 1, {});
    pocketfft::r2c<float>({n}, {sizeof(float)}, {sizeof(std::complex<float>)}, 0, true, in.data(), out.data(), 1.f);
}

std::vector<float> irfft(const cvec& spec, size_t n) {
    std::vector<float> out(n);
    pocketfft::c2r<float>({n}, {sizeof(std::complex<float>)}, {sizeof(float)}, 0, false, spec.data(), out.data(), 1.f / n);
    return out;
}

// r[k] = sum_t a[t + k] * b[t] for k in [0, n) (circular, n >= len(a) + len(b) avoids wrap for k >= 0).
std::vector<float> correlate(const std::vector<float>& a, const std::vector<float>& b, size_t n) {
    cvec A, B;
    rfft(a, n, A);
    rfft(b, n, B);
    for (size_t i = 0; i < A.size(); ++i) A[i] *= std::conj(B[i]);
    return irfft(A, n);
}

// Onset strength: log-magnitude spectral flux, minus its 0.5 s local mean,
// z-normalised. One value per 10 ms.
std::vector<float> onset_envelope(const std::vector<float>& x) {
    if (x.size() < static_cast<size_t>(kEnvFft)) return {};
    const size_t frames = (x.size() - kEnvFft) / kHop + 1;
    std::vector<float> win(kEnvFft);
    for (int i = 0; i < kEnvFft; ++i) win[i] = static_cast<float>(0.5 - 0.5 * std::cos(2 * kPi * i / kEnvFft));
    const size_t bins = kEnvFft / 2 + 1;
    std::vector<float> prev(bins, 0.f), cur(bins), frame(kEnvFft);
    cvec spec(bins);
    std::vector<float> env(frames, 0.f);
    for (size_t f = 0; f < frames; ++f) {
        for (int i = 0; i < kEnvFft; ++i) frame[i] = x[f * kHop + i] * win[i];
        pocketfft::r2c<float>({static_cast<size_t>(kEnvFft)}, {sizeof(float)}, {sizeof(std::complex<float>)}, 0, true, frame.data(), spec.data(), 1.f);
        double flux = 0;
        for (size_t k = 1; k < bins; ++k) {
            cur[k] = std::log1p(100.f * std::abs(spec[k]));
            if (f > 0) flux += std::max(0.f, cur[k] - prev[k]);
        }
        env[f] = static_cast<float>(flux);
        std::swap(prev, cur);
    }
    // Remove the slow level so loud and quiet sections weigh alike.
    const int half = 25;
    std::vector<double> pre(frames + 1, 0.0);
    for (size_t i = 0; i < frames; ++i) pre[i + 1] = pre[i] + env[i];
    std::vector<float> out(frames);
    for (size_t i = 0; i < frames; ++i) {
        const size_t a = i > static_cast<size_t>(half) ? i - half : 0, b = std::min(frames, i + half + 1);
        out[i] = std::max(0.f, env[i] - static_cast<float>((pre[b] - pre[a]) / double(b - a)));
    }
    double mean = 0, var = 0;
    for (float v : out) mean += v;
    mean /= frames;
    for (float v : out) var += (v - mean) * (v - mean);
    const double sd = std::sqrt(var / frames) + 1e-9;
    for (float& v : out) v = static_cast<float>((v - mean) / sd);
    return out;
}

std::vector<float> pre_emphasis(const std::vector<float>& x) {
    std::vector<float> y(x.size());
    for (size_t i = 0; i < x.size(); ++i) y[i] = x[i] - (i ? 0.97f * x[i - 1] : 0.f);
    return y;
}

// Mean chroma (12 pitch classes, zero mean, unit length) between 65 Hz and 2 kHz.
std::vector<double> chroma(const std::vector<float>& x, int sr) {
    const int n = 4096;
    std::vector<double> c(12, 0.0);
    if (x.size() < static_cast<size_t>(n)) return c;
    std::vector<float> win(n), frame(n);
    for (int i = 0; i < n; ++i) win[i] = static_cast<float>(0.5 - 0.5 * std::cos(2 * kPi * i / n));
    std::vector<int> pc(n / 2 + 1, -1);
    for (int k = 1; k <= n / 2; ++k) {
        const double f = double(k) * sr / n;
        if (f < 65 || f > 2000) continue;
        pc[k] = ((static_cast<int>(std::lround(12 * std::log2(f / 440.0) + 69)) % 12) + 12) % 12;
    }
    cvec spec(n / 2 + 1);
    for (size_t s = 0; s + n <= x.size(); s += n) {
        for (int i = 0; i < n; ++i) frame[i] = x[s + i] * win[i];
        pocketfft::r2c<float>({static_cast<size_t>(n)}, {sizeof(float)}, {sizeof(std::complex<float>)}, 0, true, frame.data(), spec.data(), 1.f);
        for (int k = 1; k <= n / 2; ++k)
            if (pc[k] >= 0) c[pc[k]] += std::abs(spec[k]);
    }
    const double mean = std::accumulate(c.begin(), c.end(), 0.0) / 12;
    double norm = 0;
    for (double& v : c) {
        v -= mean;
        norm += v * v;
    }
    norm = std::sqrt(norm) + 1e-12;
    for (double& v : c) v /= norm;
    return c;
}

// Best lag (frames) of eb against em over every lag with at least
// min_overlap frames in common, and the ratio of the best peak to the
// runner-up (more than 20 frames away).
std::pair<long, double> best_lag(const std::vector<float>& em, const std::vector<float>& eb, long min_overlap) {
    const size_t na = em.size(), nb = eb.size(), n = na + nb;
    const auto c = correlate(em, eb, n);
    long best = 0;
    double bv = -1e30, second = -1e30;
    std::vector<std::pair<long, double>> score;
    for (long k = -static_cast<long>(nb) + 1; k < static_cast<long>(na); ++k) {
        const long overlap = std::min<long>(na, static_cast<long>(nb) + k) - std::max<long>(0, k);
        if (overlap < min_overlap) continue;
        const double v = c[k >= 0 ? static_cast<size_t>(k) : n + k] / std::sqrt(double(overlap));
        score.emplace_back(k, v);
        if (v > bv) bv = v, best = k;
    }
    for (auto& [k, v] : score)
        if (std::abs(k - best) > 20 && v > second) second = v;
    return {best, second > 0 ? bv / second : 99};
}

double median(std::vector<double> v) {
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    const size_t m = v.size() / 2;
    return v.size() % 2 ? v[m] : 0.5 * (v[m - 1] + v[m]);
}
}  // namespace

Result align_backing(const std::vector<float>& mix, const std::vector<float>& backing, int sr) {
    Result r;
    r.mix_seconds = double(mix.size()) / sr;
    r.backing_seconds = double(backing.size()) / sr;

    // 1. Coarse: onset envelopes over every lag.
    const auto em = onset_envelope(mix), eb = onset_envelope(backing);
    if (em.size() < 300 || eb.size() < 300) {
        r.verdict = "mismatch";
        return r;
    }
    const size_t na = em.size(), nb = eb.size();
    const auto [best, ratio] = best_lag(em, eb, static_cast<long>(std::min<size_t>(1500, std::min(na, nb) / 2)));
    r.coarse_delay = best * double(kHop) / sr;
    r.coarse_peak_ratio = ratio;

    // A speed difference smears the whole-file peak: also match 30 s chunks of
    // the backing on their own and fit a line through their lags.
    double lag0 = best, lag_slope = 0;  // lag (frames) = lag0 + lag_slope * mix frame
    {
        const size_t chunk = 3000, step = 1500;
        std::vector<double> mt, lg;
        for (size_t c0 = 0; c0 + chunk <= nb; c0 += step) {
            std::vector<float> part(eb.begin() + c0, eb.begin() + c0 + chunk);
            const auto [k, pr] = best_lag(em, part, static_cast<long>(chunk * 3 / 4));
            if (pr < 1.15) continue;
            const double lag = double(k) - double(c0);   // backing frame f maps to mix frame f + lag
            mt.push_back(double(c0 + chunk / 2) + lag);
            lg.push_back(lag);
        }
        if (mt.size() >= 3) {
            // Least squares after dropping lags far from the median (edits, repeats).
            const double med = median(lg);
            std::vector<double> x, y;
            for (size_t i = 0; i < lg.size(); ++i)
                if (std::abs(lg[i] - med) < 50) x.push_back(mt[i]), y.push_back(lg[i]);
            if (x.size() >= 3) {
                const double mx = std::accumulate(x.begin(), x.end(), 0.0) / x.size(), my = std::accumulate(y.begin(), y.end(), 0.0) / x.size();
                double sxy = 0, sxx = 0;
                for (size_t i = 0; i < x.size(); ++i) sxy += (x[i] - mx) * (y[i] - my), sxx += (x[i] - mx) * (x[i] - mx);
                const double slope = sxx > 0 ? sxy / sxx : 0;
                // Use the chunk fit when the whole-file peak is weak or the lags drift.
                if (ratio < 1.25 || std::abs(slope) > 300e-6) {
                    lag_slope = slope;
                    lag0 = my - slope * mx;
                    r.coarse_delay = lag0 * double(kHop) / sr;
                }
            }
        }
    }

    // 2. Fine: waveform windows around the coarse lag.
    const auto pm = pre_emphasis(mix), pb = pre_emphasis(backing);
    const long D0 = std::lround(lag0 * kHop);  // coarse delay at the start (samples)
    const long W = 2 * sr, M = sr * 60 / 1000;
    const long Dend = std::lround((lag0 + lag_slope * double(mix.size()) / kHop) * kHop);
    const long lo = std::max<long>({0L, D0, Dend}), hi = std::min<long>({static_cast<long>(mix.size()), static_cast<long>(backing.size()) + D0, static_cast<long>(backing.size()) + Dend});
    const long span = hi - lo - W - 2 * M;
    const int count = span <= 0 ? 0 : static_cast<int>(std::clamp<long>(span / (W * 2), 1, 16));
    for (int w = 0; w < count; ++w) {
        const long s = lo + M + (count == 1 ? span / 2 : span * w / (count - 1));
        const long D = std::lround((lag0 + lag_slope * double(s + W / 2) / kHop) * kHop);  // coarse delay here
        std::vector<float> x(pm.begin() + s, pm.begin() + s + W), xr(mix.begin() + s, mix.begin() + s + W);
        const long b0 = s - D - M;  // backing index of y[0]
        std::vector<float> y(W + 2 * M, 0.f), yr(W + 2 * M, 0.f);
        for (long i = 0; i < W + 2 * M; ++i) {
            const long bi = b0 + i;
            if (bi >= 0 && bi < static_cast<long>(backing.size())) y[i] = pb[bi], yr[i] = backing[bi];
        }
        double ex = 0;
        for (float v : x) ex += double(v) * v;
        // Sliding energy of y over W samples.
        std::vector<double> ey(2 * M + 1);
        double e = 0;
        for (long i = 0; i < W; ++i) e += double(y[i]) * y[i];
        for (long k = 0; k <= 2 * M; ++k) {
            ey[k] = e;
            if (k < 2 * M) e += double(y[k + W]) * y[k + W] - double(y[k]) * y[k];
        }
        if (ex < 1e-6 * W) continue;  // silence in the mix here
        size_t fft_n = 1;
        while (fft_n < static_cast<size_t>(W + 2 * M + W)) fft_n <<= 1;
        const auto rc = correlate(y, x, fft_n);  // rc[k] = sum_t y[t + k] x[t]
        long kb = 0;
        double vb = 0;
        std::vector<double> nr(2 * M + 1, 0.0);
        for (long k = 0; k <= 2 * M; ++k) {
            nr[k] = ey[k] > 1e-12 ? rc[k] / std::sqrt(ex * ey[k]) : 0.0;
            if (std::abs(nr[k]) > std::abs(vb)) vb = nr[k], kb = k;
        }
        double frac = 0;
        if (kb > 0 && kb < 2 * M) {
            const double a = std::abs(nr[kb - 1]), b = std::abs(nr[kb]), cc = std::abs(nr[kb + 1]);
            const double den = a - 2 * b + cc;
            if (den < 0) frac = 0.5 * (a - cc) / den;
        }
        Window win;
        win.t = double(s) / sr;
        win.delay = double(D + (M - (kb + frac))) / sr;
        win.corr = vb;
        // Residual of the plain signals at the integer peak.
        double xy = 0, yy = 0, xx = 0;
        for (long t = 0; t < W; ++t) {
            xy += double(xr[t]) * yr[t + kb];
            yy += double(yr[t + kb]) * yr[t + kb];
            xx += double(xr[t]) * xr[t];
        }
        win.gain = yy > 0 ? xy / yy : 0;
        const double resid = std::max(1e-12, xx - win.gain * xy);
        win.cancel_db = 10 * std::log10(resid / std::max(1e-12, xx));
        r.windows.push_back(win);
    }

    // 3. Fit and checks.
    std::vector<double> ts, ds;
    for (auto& w : r.windows)
        if (std::abs(w.corr) >= 0.15) {
            w.used = true;
            ts.push_back(w.t);
            ds.push_back(w.delay);
        }
    const size_t used = ts.size();
    if (used >= 2) {
        const double mt = std::accumulate(ts.begin(), ts.end(), 0.0) / used, md = std::accumulate(ds.begin(), ds.end(), 0.0) / used;
        double sxy = 0, sxx = 0;
        for (size_t i = 0; i < used; ++i) sxy += (ts[i] - mt) * (ds[i] - md), sxx += (ts[i] - mt) * (ts[i] - mt);
        const double slope = sxx > 0 ? sxy / sxx : 0, icpt = md - slope * mt;
        double ss = 0;
        for (size_t i = 0; i < used; ++i) ss += std::pow(ds[i] - (icpt + slope * ts[i]), 2);
        r.spread_ms = 1000 * std::sqrt(ss / used);
        r.drift_ppm = slope * 1e6;
        const double span_s = ts.back() - ts.front();
        if (used >= 3 && r.spread_ms > 3) {
            r.verdict = "mismatch";
            r.delay = median(ds);
        } else if (std::abs(slope) * std::max(span_s, r.mix_seconds) > 0.004) {
            r.verdict = "drift";
            r.delay = icpt;
        } else {
            r.verdict = "aligned";
            r.delay = median(ds);
            r.drift_ppm = 0;
        }
    } else {
        r.verdict = "mismatch";
        r.delay = r.coarse_delay;
    }
    std::vector<double> cancels, gains, corrs;
    for (auto& w : r.windows)
        if (w.used) cancels.push_back(w.cancel_db), gains.push_back(w.gain), corrs.push_back(std::abs(w.corr));
    r.cancel_db = median(cancels);
    r.gain = median(gains);

    // 4. Band check: on up to 60 s of the overlap, the residual offset of
    // each band with GCC-PHAT (only the phase counts, so the loudest band
    // does not decide for the others).
    if (r.verdict == "aligned") {
        const long Df = std::lround(r.delay * sr);
        const long blo = std::max<long>(0, Df), bhi = std::min<long>(mix.size(), static_cast<long>(backing.size()) + Df);
        const long L = std::min<long>(bhi - blo, 60L * sr);
        if (L > 4L * sr) {
            const long s0 = blo + (bhi - blo - L) / 2;
            std::vector<float> x(mix.begin() + s0, mix.begin() + s0 + L), y(backing.begin() + (s0 - Df), backing.begin() + (s0 - Df) + L);
            size_t nfft = 1;
            while (nfft < static_cast<size_t>(2 * L)) nfft <<= 1;
            cvec X, Y;
            rfft(x, nfft, X);
            rfft(y, nfft, Y);
            double etotal = 0;
            for (size_t k = 1; k < X.size(); ++k) etotal += std::norm(X[k]);
            const long M = sr * 20 / 1000;  // +-20 ms
            const double edges[][2] = {{30, 150}, {150, 500}, {500, 1500}, {1500, 0.475 * sr}};
            std::vector<double> used_offsets;
            for (const auto& e : edges) {
                const size_t k0 = static_cast<size_t>(std::ceil(e[0] * nfft / sr)), k1 = std::min(X.size() - 1, static_cast<size_t>(e[1] * nfft / sr));
                if (k1 <= k0) continue;
                cvec C(X.size(), {0.f, 0.f});
                double eb = 0;
                for (size_t k = k0; k <= k1; ++k) {
                    const auto c = X[k] * std::conj(Y[k]);
                    const float mag = std::abs(c);
                    if (mag > 0) C[k] = c / mag;
                    eb += std::norm(X[k]);
                }
                const auto rr = irfft(C, nfft);  // rr[l] = sum x[t + l] y[t]
                auto at = [&](long l) { return double(rr[l >= 0 ? static_cast<size_t>(l) : nfft + l]); };
                long lb = 0;
                double vb = -1e30;
                for (long l = -M; l <= M; ++l)
                    if (at(l) > vb) vb = at(l), lb = l;
                double frac = 0;
                const double a = at(lb - 1), b = at(lb), c = at(lb + 1), den = a - 2 * b + c;
                if (den < 0) frac = 0.5 * (a - c) / den;
                Band band;
                band.lo = e[0];
                band.hi = e[1];
                band.offset_ms = 1000.0 * (lb + frac) / sr;
                // A perfectly coherent band gives a peak of (bins / nfft) * 2.
                band.coherence = std::clamp(vb * nfft / (2.0 * double(k1 - k0 + 1)), 0.0, 1.0);
                band.energy = etotal > 0 ? eb / etotal : 0;
                band.used = band.coherence >= 0.1 && band.energy >= 0.01;
                if (band.used) used_offsets.push_back(band.offset_ms);
                r.bands.push_back(band);
            }
            if (used_offsets.size() >= 2) {
                const auto [mn, mx] = std::minmax_element(used_offsets.begin(), used_offsets.end());
                r.band_spread_ms = *mx - *mn;
                r.band_warning = r.band_spread_ms > 2.0;
            }
        }
    }

    // Key: compare mean chroma of the two.
    const auto cm = chroma(mix, sr), cb = chroma(backing, sr);
    double kbv = -2, ksec = -2;
    for (int s = -6; s < 6; ++s) {
        double v = 0;
        for (int i = 0; i < 12; ++i) v += cm[i] * cb[((i + s) % 12 + 12) % 12];
        if (v > kbv) ksec = kbv, kbv = v, r.key_shift = s;
        else if (v > ksec) ksec = v;
    }
    r.key_margin = kbv - ksec;

    const double frac_used = r.windows.empty() ? 0 : double(used) / r.windows.size();
    const double peak = std::clamp((r.coarse_peak_ratio - 1.0) / 0.5, 0.0, 1.0);
    r.confidence = r.verdict == "mismatch" ? 0.2 * peak : std::clamp(median(corrs) * 1.5, 0.0, 1.0) * frac_used * (0.5 + 0.5 * peak);
    return r;
}

std::string to_json(const Result& r) {
    std::string s;
    char buf[512];
    snprintf(buf, sizeof buf,
             "{\"verdict\":\"%s\",\"delay\":%.6f,\"confidence\":%.3f,\"coarse_delay\":%.3f,\"coarse_peak_ratio\":%.3f,"
             "\"drift_ppm\":%.1f,\"spread_ms\":%.3f,\"cancel_db\":%.2f,\"gain\":%.4f,\"key_shift\":%d,\"key_margin\":%.3f,"
             "\"mix_seconds\":%.3f,\"backing_seconds\":%.3f,\"windows\":[",
             r.verdict.c_str(), r.delay, r.confidence, r.coarse_delay, r.coarse_peak_ratio, r.drift_ppm, r.spread_ms, r.cancel_db,
             r.gain, r.key_shift, r.key_margin, r.mix_seconds, r.backing_seconds);
    s += buf;
    for (size_t i = 0; i < r.windows.size(); ++i) {
        const auto& w = r.windows[i];
        snprintf(buf, sizeof buf, "%s{\"t\":%.2f,\"delay\":%.6f,\"corr\":%.3f,\"cancel_db\":%.2f,\"gain\":%.4f,\"used\":%s}", i ? "," : "", w.t,
                 w.delay, w.corr, w.cancel_db, w.gain, w.used ? "true" : "false");
        s += buf;
    }
    s += "],\"bands\":[";
    for (size_t i = 0; i < r.bands.size(); ++i) {
        const auto& b = r.bands[i];
        snprintf(buf, sizeof buf, "%s{\"lo\":%.0f,\"hi\":%.0f,\"offset_ms\":%.3f,\"coherence\":%.3f,\"energy\":%.3f,\"used\":%s}", i ? "," : "",
                 b.lo, b.hi, b.offset_ms, b.coherence, b.energy, b.used ? "true" : "false");
        s += buf;
    }
    snprintf(buf, sizeof buf, "],\"band_spread_ms\":%.3f,\"band_warning\":%s}", r.band_spread_ms, r.band_warning ? "true" : "false");
    s += buf;
    return s;
}

}  // namespace ke::align
