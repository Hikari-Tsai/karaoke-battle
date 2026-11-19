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

// Residual offset of one frequency band after the overall delay is applied
// (GCC-PHAT on that band only): every band should agree with the others when
// the two are the same mix.
struct Band {
    double lo = 0, hi = 0;    // Hz
    double offset_ms = 0;     // more delay this band would want (same sign as Result::delay)
    double coherence = 0;     // PHAT peak height, 0..1 (how clearly the band lines up)
    double energy = 0;        // share of the reference's energy in this band
    bool used = false;        // clear enough to count in band_spread_ms
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
    // Per-band check (same version only): bands that disagree mean the two
    // were mixed or rendered differently (e.g. a plugin delaying the bass).
    std::vector<Band> bands;
    double band_spread_ms = 0;     // max - min offset over the used bands
    bool band_warning = false;     // band_spread_ms above 2 ms
};

// Both mono at the same sample rate. The reference is best the song's
// separated accompaniment (same timeline as the mix, without the vocal onsets
// that otherwise blur the match); the original mix also works.
Result align_backing(const std::vector<float>& mix, const std::vector<float>& backing, int sample_rate);

std::string to_json(const Result& r);

}  // namespace ke::align
