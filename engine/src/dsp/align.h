// Aligns a user-supplied backing track (an official instrumental, a karaoke
// track) with a song's original mix, so it can stand in for the separated
// accompaniment on the song's timeline.
//
//   1. coarse: cross-correlation of onset-strength envelopes (10 ms frames),
//      over every lag, so intros of different length are found;
//   2. fine: cross-correlation of the (pre-emphasised) waveforms at 8 kHz in a
//      few windows across the song, within +-60 ms of the coarse lag, with
//      parabolic interpolation (sub-sample);
//   3. checks: the windows' delays should agree (same version); a linear trend
//      is a speed difference (drift), scattered delays a different version;
//      the residual mix - gain * backing (about the vocals when aligned) gives
//      the cancellation; mean chroma gives a key difference.
#pragma once
#include <string>
#include <vector>

namespace ke::align {

struct Window {
    double t = 0;          // window start on the mix timeline (s)
    double delay = 0;      // backing delay found here (s)
    double corr = 0;       // normalised correlation at the peak (-1..1)
    double cancel_db = 0;  // residual energy vs the mix (dB, lower = better)
    double gain = 0;       // least-squares gain of the backing
    bool used = false;     // counted in the fit
};

struct Result {
    // Delay to apply to the backing so it lines up with the mix: positive =
    // pad the start with silence, negative = cut that much from its start.
    double delay = 0;
    double coarse_delay = 0;
    double coarse_peak_ratio = 0;  // best / runner-up envelope correlation peak
    double drift_ppm = 0;          // backing runs this much slower (+) or faster (-)
    double spread_ms = 0;          // scatter of the windows' delays around the fit
    double cancel_db = 0;          // median over the used windows
    double gain = 0;               // median over the used windows
    int key_shift = 0;             // the backing is this many semitones above the mix
    double key_margin = 0;         // best minus runner-up chroma correlation
    double mix_seconds = 0, backing_seconds = 0;
    double confidence = 0;         // 0..1
    std::string verdict;           // aligned | drift | mismatch
    std::vector<Window> windows;
};

// Both mono at the same sample rate.
Result align_backing(const std::vector<float>& mix, const std::vector<float>& backing, int sample_rate);

std::string to_json(const Result& r);

}  // namespace ke::align
