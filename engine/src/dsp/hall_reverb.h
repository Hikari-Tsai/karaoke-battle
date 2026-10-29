// Hall reverb for the singer's voice, built on the Cloud Seed core
// (Ghost Note Audio, MIT, third_party/cloudseed). Mono in, stereo out.
//
// One fixed "vocal hall" program; callers only choose the wet/dry mix.
// process() allocates nothing and is safe on the audio thread; construction
// allocates (~6 MB per channel) and is not.
#pragma once
#include <memory>
#include <vector>

namespace Cloudseed { class ReverbChannel; }

namespace ke {

class HallReverb {
public:
    static constexpr int kMaxSampleRate = 48000;   // vendored buffers are sized for 48 kHz
    static constexpr int kBlock = 1024;            // largest internal block

    explicit HallReverb(int sample_rate);
    ~HallReverb();
    HallReverb(const HallReverb&) = delete;
    HallReverb& operator=(const HallReverb&) = delete;

    int sample_rate() const { return sr_; }

    // Wet signal only (no dry), any length. in may alias neither output.
    void process_wet(const float* in, float* out_l, float* out_r, int n);
    // Zeroes every delay line (not real-time safe: touches ~12 MB).
    void clear();

    // Measured RT60 of the program (ke_cli reverb on an impulse); the late
    // lines are set shorter because the in-loop diffusers lengthen the tail.
    static constexpr double kDecaySeconds = 2.3;
    static constexpr double kLateLineDecay = 1.35;

private:
    int sr_;
    std::unique_ptr<Cloudseed::ReverbChannel> l_, r_;
    std::vector<float> in_, wl_, wr_;
};

// Dry/wet mix used everywhere the voice is reverberated, so the live return
// and the replay sound the same. mix in [0, 1].
inline float reverb_dry_gain(float mix) { return 1.f - mix; }
inline float reverb_wet_gain(float mix) { return mix; }

}  // namespace ke
