#include "dsp/hall_reverb.h"

#include <algorithm>
#include <cstring>

// Vendored code: keep its harmless warnings (unused fields, macro redefinition) out of our build log.
#if defined(__clang__) || defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-private-field"
#pragma GCC diagnostic ignored "-Wmacro-redefined"
#pragma GCC diagnostic ignored "-Wpragmas"
#pragma GCC diagnostic ignored "-Wunknown-warning-option"
#endif
#include "cloudseed/DSP/ReverbChannel.h"
#if defined(__clang__) || defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

namespace ke {

namespace P = Cloudseed::Parameter;

// Brings the wet level to roughly the dry level for a sung phrase, so mix
// behaves like a balance control: on a sung vocal stem the full-wet signal
// sits about 1 dB under the dry one (measured with ke_cli reverb).
static constexpr float kWetTrim = 0.8f;

static void apply_hall(Cloudseed::ReverbChannel& c) {
    // Values are in the units ReverbChannel::SetParameter expects (ms, Hz, dB, s).
    const std::pair<int, double> program[] = {
        {P::Interpolation, 1},
        {P::LowCutEnabled, 1}, {P::LowCut, 120},          // keep low-end mud out of the tail
        {P::HighCutEnabled, 1}, {P::HighCut, 9000},       // and sibilance
        {P::InputMix, 0},
        {P::DryOut, -30},                                 // -30 dB = muted: wet only
        {P::EarlyOut, -6}, {P::LateOut, 0},
        {P::TapEnabled, 0}, {P::TapCount, 1}, {P::TapDecay, 1}, {P::TapLength, 100},
        {P::TapPredelay, 22},                             // pre-delay keeps the words clear
        {P::EarlyDiffuseEnabled, 1}, {P::EarlyDiffuseCount, 4}, {P::EarlyDiffuseDelay, 40},
        {P::EarlyDiffuseModAmount, 0.6}, {P::EarlyDiffuseFeedback, 0.7}, {P::EarlyDiffuseModRate, 0.4},
        {P::LateMode, 1}, {P::LateLineCount, 6},
        {P::LateDiffuseEnabled, 1}, {P::LateDiffuseCount, 4},
        {P::LateLineSize, 110}, {P::LateLineModAmount, 0.5}, {P::LateLineModRate, 0.35},
        {P::LateDiffuseDelay, 45}, {P::LateDiffuseModAmount, 0.3}, {P::LateDiffuseModRate, 0.5},
        {P::LateDiffuseFeedback, 0.65},
        {P::LateLineDecay, HallReverb::kLateLineDecay},
        {P::EqLowShelfEnabled, 1}, {P::EqLowFreq, 250}, {P::EqLowGain, -4},
        {P::EqHighShelfEnabled, 1}, {P::EqHighFreq, 4500}, {P::EqHighGain, -5},
        {P::EqLowpassEnabled, 1}, {P::EqCutoff, 10000},
        {P::EqCrossSeed, 0},                              // different seeds left/right: wide stereo
        {P::SeedTap, 333}, {P::SeedDiffusion, 185}, {P::SeedDelay, 218}, {P::SeedPostDiffusion, 365},
    };
    for (const auto& [id, v] : program) c.SetParameter(id, v);
}

HallReverb::HallReverb(int sample_rate)
    : sr_(std::clamp(sample_rate, 8000, kMaxSampleRate)),
      l_(std::make_unique<Cloudseed::ReverbChannel>(sr_, Cloudseed::ChannelLR::Left)),
      r_(std::make_unique<Cloudseed::ReverbChannel>(sr_, Cloudseed::ChannelLR::Right)),
      in_(kBlock), wl_(kBlock), wr_(kBlock) {
    static_assert(kBlock <= CLOUDSEED_BUFFER_SIZE, "block larger than the Cloud Seed scratch buffers");
    apply_hall(*l_);
    apply_hall(*r_);
    // Re-applies every parameter at this rate and clears the lines.
    l_->SetSamplerate(sr_);
    r_->SetSamplerate(sr_);
}

HallReverb::~HallReverb() = default;

void HallReverb::clear() {
    l_->ClearBuffers();
    r_->ClearBuffers();
}

void HallReverb::process_wet(const float* in, float* out_l, float* out_r, int n) {
    int done = 0;
    while (done < n) {
        const int k = std::min(kBlock, n - done);
        // Clamp the input: a capture glitch must not ring through the hall.
        for (int i = 0; i < k; ++i) in_[i] = std::clamp(in[done + i], -1.f, 1.f);
        l_->Process(in_.data(), wl_.data(), k);
        r_->Process(in_.data(), wr_.data(), k);
        for (int i = 0; i < k; ++i) {
            out_l[done + i] = wl_[i] * kWetTrim;
            out_r[done + i] = wr_[i] * kWetTrim;
        }
        done += k;
    }
}

}  // namespace ke
