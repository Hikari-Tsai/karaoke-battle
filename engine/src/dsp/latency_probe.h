// Round-trip latency probe: the signal played during calibration and the
// matched filter that finds it in the microphone recording.
//
// The probe starts with a soft wake-up tone (USB speakers, S/PDIF receivers
// and amplifiers with auto-standby drop the first part of a new stream, issue
// #5), then plays short frequency sweeps (chirps). A chirp carries far more
// energy than a click of the same peak level and compresses to a sharp
// correlation peak, so a quiet or distant microphone still finds it.
// No audio device here: audio_engine.cpp plays `out` and records, and
// tools/calib_eval.cpp tests the analysis on synthetic recordings.
#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace ke {

struct LatencyProbe {
    int sample_rate = 0;
    std::vector<float> out;        // what is played, mono
    // One template per chirp, alternating up and down sweeps: a template
    // then hardly matches its neighbours, which also fall in the lag window.
    std::vector<std::vector<float>> chirps;
    std::vector<size_t> starts;    // where each chirp starts in `out`
    size_t record_frames = 0;      // how much to record (out + the largest lag)
};

/// Longest round trip the analysis looks for, in seconds.
constexpr double kLatencyProbeMaxLag = 0.5;

LatencyProbe make_latency_probe(int sample_rate);

struct LatencyResult {
    bool ok = false;
    double roundtrip = 0.0;              // seconds, median over the chirps found
    std::vector<double> per_chirp;       // seconds; < 0 for a chirp not found
    int found = 0;                       // chirps that agree with the result
    double prominence = 0.0;             // correlation peak / mean
    double input_peak = 0.0;             // linear peak of the recording
    std::string error;                   // why not ok
};

/// Finds the probe in [rec] (recorded from the moment `out` started playing).
LatencyResult measure_latency(const LatencyProbe& probe, const std::vector<float>& rec);

}  // namespace ke
