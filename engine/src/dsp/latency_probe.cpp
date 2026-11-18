#include "dsp/latency_probe.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace ke {
namespace {

constexpr double kPi = 3.14159265358979323846;

// Wake-up tone: soft, so it is heard but not startling.
constexpr double kWakeEnd = 0.9;          // seconds
constexpr double kWakeFade = 0.15;
constexpr double kWakeHz = 660.0;
constexpr double kWakeAmp = 0.06;         // about -24 dBFS

// Chirps: exponential sweep, tapered ends.
constexpr int kChirps = 6;
constexpr double kFirstChirp = 1.2;       // seconds; after the wake-up tone
constexpr double kChirpSpacing = 0.3;     // inside the lag window: neighbours differ (up/down)
constexpr double kChirpSeconds = 0.040;
constexpr double kChirpTaper = 0.004;
constexpr double kChirpF0 = 1000.0;
constexpr double kChirpF1 = 5000.0;
constexpr double kChirpAmp = 0.5;

// Analysis thresholds.
constexpr double kMinPeak = 1e-4;         // -80 dBFS: the input is silent
constexpr double kMinProminence = 6.0;    // correlation peak / mean
constexpr double kRefine = 0.003;         // per-chirp search around the common peak, seconds
constexpr int kMinFound = 3;

double db(double v) { return 20.0 * std::log10(std::max(v, 1e-7)); }

}  // namespace

LatencyProbe make_latency_probe(int sample_rate) {
    LatencyProbe p;
    p.sample_rate = sample_rate;
    const double sr = sample_rate;

    const size_t clen = static_cast<size_t>(kChirpSeconds * sr);
    const double f1 = std::min(kChirpF1, 0.45 * sr);
    const double k = f1 / kChirpF0;
    const double taper = kChirpTaper * sr;
    std::vector<float> up(clen);
    for (size_t i = 0; i < clen; ++i) {
        const double t = i / sr;
        const double phase = 2.0 * kPi * kChirpF0 * kChirpSeconds / std::log(k) * (std::pow(k, t / kChirpSeconds) - 1.0);
        double w = 1.0;
        if (i < taper) w = 0.5 - 0.5 * std::cos(kPi * i / taper);
        else if (clen - 1 - i < taper) w = 0.5 - 0.5 * std::cos(kPi * (clen - 1 - i) / taper);
        up[i] = static_cast<float>(kChirpAmp * w * std::sin(phase));
    }
    const std::vector<float> down(up.rbegin(), up.rend());

    for (int c = 0; c < kChirps; ++c) {
        p.starts.push_back(static_cast<size_t>((kFirstChirp + c * kChirpSpacing) * sr));
        p.chirps.push_back(c % 2 == 0 ? up : down);
    }
    p.out.assign(p.starts.back() + clen + static_cast<size_t>(0.05 * sr), 0.f);

    const size_t wake_end = static_cast<size_t>(kWakeEnd * sr);
    const double fade = kWakeFade * sr;
    for (size_t i = 0; i < wake_end; ++i) {
        double w = 1.0;
        if (i < fade) w = 0.5 - 0.5 * std::cos(kPi * i / fade);
        else if (wake_end - i < fade) w = 0.5 - 0.5 * std::cos(kPi * (wake_end - i) / fade);
        p.out[i] = static_cast<float>(kWakeAmp * w * std::sin(2.0 * kPi * kWakeHz * i / sr));
    }
    for (size_t c = 0; c < p.starts.size(); ++c)
        for (size_t i = 0; i < clen; ++i) p.out[p.starts[c] + i] += p.chirps[c][i];

    p.record_frames = p.out.size() + static_cast<size_t>(kLatencyProbeMaxLag * sr);
    return p;
}

LatencyResult measure_latency(const LatencyProbe& probe, const std::vector<float>& rec) {
    LatencyResult r;
    const double sr = probe.sample_rate;
    const size_t n = probe.starts.size();
    const size_t max_lag = static_cast<size_t>(kLatencyProbeMaxLag * sr);
    for (float v : rec) r.input_peak = std::max(r.input_peak, double(std::fabs(v)));

    // Matched filter per chirp: |<chirp, rec shifted by lag>|.
    std::vector<std::vector<float>> corr(n, std::vector<float>(max_lag, 0.f));
    for (size_t c = 0; c < n; ++c) {
        const size_t s0 = probe.starts[c];
        const std::vector<float>& tpl = probe.chirps[c];
        const size_t clen = tpl.size();
        for (size_t lag = 0; lag < max_lag; ++lag) {
            const size_t at = s0 + lag;
            if (at + clen > rec.size()) break;
            const float* x = rec.data() + at;
            float acc = 0.f;
            for (size_t i = 0; i < clen; ++i) acc += tpl[i] * x[i];
            corr[c][lag] = std::fabs(acc);
        }
    }

    // The common lag: the sum over chirps, so a chirp the speaker swallowed
    // only adds noise.
    std::vector<double> sum(max_lag, 0.0);
    for (size_t c = 0; c < n; ++c)
        for (size_t lag = 0; lag < max_lag; ++lag) sum[lag] += corr[c][lag];
    size_t best = 0;
    double peak = 0.0, mean = 0.0;
    for (size_t lag = 0; lag < max_lag; ++lag) {
        if (sum[lag] > peak) { peak = sum[lag]; best = lag; }
        mean += sum[lag];
    }
    mean /= std::max<size_t>(1, max_lag);
    r.prominence = mean > 0 ? peak / mean : 0.0;

    char buf[256];
    if (r.input_peak < kMinPeak || r.prominence < kMinProminence) {
        std::snprintf(buf, sizeof buf,
                      "no click detected in the recording (input peak %.1f dBFS, peak/mean %.1f): is the microphone enabled and able to hear the speakers?",
                      db(r.input_peak), r.prominence);
        r.error = buf;
        return r;
    }

    // Each chirp near the common lag; keep those that stand out.
    const long half = static_cast<long>(kRefine * sr);
    std::vector<double> vals(n, 0.0), means(n, 0.0);
    std::vector<size_t> lags(n, best);
    for (size_t c = 0; c < n; ++c) {
        for (long d = -half; d <= half; ++d) {
            const long lag = static_cast<long>(best) + d;
            if (lag < 0 || lag >= static_cast<long>(max_lag)) continue;
            if (corr[c][lag] > vals[c]) { vals[c] = corr[c][lag]; lags[c] = static_cast<size_t>(lag); }
        }
        double m = 0.0;
        for (float v : corr[c]) m += v;
        means[c] = m / std::max<size_t>(1, max_lag);
    }
    const double strongest = *std::max_element(vals.begin(), vals.end());
    std::vector<double> found;
    r.per_chirp.assign(n, -1.0);
    for (size_t c = 0; c < n; ++c) {
        if (vals[c] >= 0.25 * strongest && vals[c] >= kMinProminence * means[c]) {
            r.per_chirp[c] = double(lags[c]) / sr;
            found.push_back(r.per_chirp[c]);
        }
    }
    r.found = static_cast<int>(found.size());
    if (r.found < kMinFound) {
        std::snprintf(buf, sizeof buf,
                      "no click detected clearly enough (only %d of %zu sweeps heard, input peak %.1f dBFS, peak/mean %.1f): is the microphone enabled and able to hear the speakers?",
                      r.found, n, db(r.input_peak), r.prominence);
        r.error = buf;
        return r;
    }
    std::sort(found.begin(), found.end());
    r.roundtrip = found[found.size() / 2];
    r.ok = true;
    return r;
}

}  // namespace ke
