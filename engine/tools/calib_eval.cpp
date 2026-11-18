// Latency calibration on synthetic recordings (development tool, issue #5).
//
//   ke_calib_eval            run every scenario, exit 1 if one fails
//
// Each scenario plays the probe through a crude speaker + room + microphone
// model (delay, gain, band limits, one reflection, noise, the start of the
// stream swallowed) and checks the measured round trip. The old probe (five
// 2 ms clicks at 1.5 kHz) runs on the same model for comparison.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

#include "dsp/latency_probe.h"

namespace {

constexpr double kPi = 3.14159265358979323846;

struct Room {
    double delay = 0.060;      // round trip, seconds
    double gain_db = -30.0;    // speaker -> microphone
    double noise_db = -70.0;   // white noise RMS, dBFS
    double swallow = 0.0;      // seconds lost at the start of the stream
    bool invert = false;       // polarity
    double hz = 48000;
};

std::vector<float> through(const std::vector<float>& out, size_t frames, const Room& room, unsigned seed) {
    const double sr = room.hz;
    std::vector<double> x(out.begin(), out.end());
    for (size_t i = 0; i < x.size() && i < static_cast<size_t>(room.swallow * sr); ++i) x[i] = 0.0;
    // Small speaker: high-pass ~300 Hz, low-pass ~7 kHz (one pole each).
    const double hp = std::exp(-2.0 * kPi * 300.0 / sr), lp = std::exp(-2.0 * kPi * 7000.0 / sr);
    double hx = 0, hy = 0, ly = 0;
    for (double& v : x) {
        const double h = hp * (hy + v - hx);
        hx = v; hy = h;
        ly = (1 - lp) * h + lp * ly;
        v = ly;
    }
    std::vector<float> rec(frames, 0.f);
    const double g = std::pow(10.0, room.gain_db / 20.0) * (room.invert ? -1 : 1);
    const size_t d = static_cast<size_t>(room.delay * sr), echo = static_cast<size_t>(0.007 * sr);
    for (size_t i = 0; i < x.size(); ++i) {
        if (i + d < frames) rec[i + d] += static_cast<float>(g * x[i]);
        if (i + d + echo < frames) rec[i + d + echo] += static_cast<float>(0.4 * g * x[i]);
    }
    std::mt19937 rng(seed);
    std::normal_distribution<double> n(0.0, std::pow(10.0, room.noise_db / 20.0));
    for (float& v : rec) v += static_cast<float>(n(rng));
    return rec;
}

// The probe before issue #5, as audio_engine.cpp had it.
struct OldResult { bool ok; double roundtrip; };
OldResult old_probe(const Room& room, unsigned seed) {
    const double sr = room.hz;
    const size_t total = static_cast<size_t>(1.5 * sr);
    std::vector<float> out(total, 0.f);
    const int len = std::max(8, static_cast<int>(0.002 * sr));
    std::vector<size_t> starts;
    for (int k = 0; k < 5; ++k) {
        const size_t s0 = static_cast<size_t>((0.2 + k * 0.2) * sr);
        starts.push_back(s0);
        for (int i = 0; i < len; ++i) {
            const double w = 0.5 - 0.5 * std::cos(2.0 * kPi * i / (len - 1));
            out[s0 + i] = static_cast<float>(0.6 * w * std::sin(2.0 * kPi * 1500.0 * i / sr));
        }
    }
    const std::vector<float> rec = through(out, total, room, seed);
    std::vector<size_t> nz;
    for (size_t i = 0; i < out.size(); ++i) if (out[i] != 0.f) nz.push_back(i);
    const size_t max_lag = static_cast<size_t>(0.45 * sr);
    double peak = 0, mean = 0, rec_peak = 0;
    size_t best = 0;
    for (float v : rec) rec_peak = std::max(rec_peak, double(std::fabs(v)));
    for (size_t lag = 0; lag < max_lag; ++lag) {
        double s = 0;
        for (size_t i : nz) if (i + lag < rec.size()) s += double(out[i]) * rec[i + lag];
        s = std::fabs(s);
        if (s > peak) { peak = s; best = lag; }
        mean += s;
    }
    mean /= max_lag;
    if (rec_peak < 1e-4 || peak / mean < 6.0) return {false, 0};
    return {true, double(best) / sr};
}

}  // namespace

int main() {
    struct Case { std::string name; Room room; bool expect_ok; };
    std::vector<Case> cases;
    auto add = [&](const std::string& name, Room r, bool ok = true) { cases.push_back({name, r, ok}); };
    add("clean, 60 ms", Room{});
    add("44.1 kHz, 23 ms", Room{0.023, -30, -70, 0, false, 44100});
    add("96 kHz, 140 ms", Room{0.140, -30, -70, 0, false, 96000});
    add("long round trip 420 ms", Room{0.420});
    add("inverted polarity", Room{0.060, -30, -70, 0, true});
    add("quiet: speaker -50 dB, noise -60 dBFS", Room{0.075, -50, -60});
    add("very quiet: speaker -60 dB, noise -58 dBFS", Room{0.075, -60, -58});
    add("faint: speaker -68 dB, noise -60 dBFS", Room{0.075, -68, -60});
    add("fainter: speaker -74 dB, noise -60 dBFS", Room{0.075, -74, -60}, false);  // beyond reach: documents the limit
    add("first 0.5 s swallowed (S/PDIF lock)", Room{0.080, -35, -65, 0.5});
    add("first 1.1 s swallowed (amp waking up)", Room{0.080, -35, -65, 1.1});
    add("first 1.8 s swallowed (3 of 6 sweeps left)", Room{0.080, -35, -65, 1.8});
    add("silence: no sound reaches the mic", Room{0.060, -200, -48}, false);
    add("first 2.4 s swallowed (1 sweep left)", Room{0.080, -35, -65, 2.4}, false);

    int failures = 0;
    std::printf("%-46s %-24s %s\n", "scenario", "new probe", "old probe (2 ms clicks)");
    unsigned seed = 1;
    for (const Case& c : cases) {
        const ke::LatencyProbe probe = ke::make_latency_probe(static_cast<int>(c.room.hz));
        const auto rec = through(probe.out, probe.record_frames, c.room, seed);
        const ke::LatencyResult r = ke::measure_latency(probe, rec);
        const OldResult o = old_probe(c.room, seed);
        ++seed;
        // The model adds the echo 7 ms late and the filters a little group
        // delay; the direct path must win within 1 ms.
        const bool right = r.ok && std::fabs(r.roundtrip - c.room.delay) < 0.001;
        const bool pass = c.expect_ok ? right : !r.ok;
        if (!pass) ++failures;
        char nw[64], od[64];
        if (r.ok) std::snprintf(nw, sizeof nw, "%.1f ms (%d/6, p/m %.0f)", r.roundtrip * 1000, r.found, r.prominence);
        else std::snprintf(nw, sizeof nw, "fail (p/m %.1f)", r.prominence);
        if (o.ok) std::snprintf(od, sizeof od, "%.1f ms%s", o.roundtrip * 1000, std::fabs(o.roundtrip - c.room.delay) < 0.001 ? "" : " WRONG");
        else std::snprintf(od, sizeof od, "fail");
        std::printf("%s %-44s %-24s %s\n", pass ? "ok  " : "FAIL", c.name.c_str(), nw, od);
        if (!pass && !r.ok) std::printf("       %s\n", r.error.c_str());
    }
    std::printf("%s\n", failures ? "FAILED" : "all scenarios passed");
    return failures ? 1 : 0;
}
