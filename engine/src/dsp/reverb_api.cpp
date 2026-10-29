// Offline hall reverb render (ke_reverb_render_wav).
#include "karaoke_engine.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "core/error.h"
#include "core/resample.h"
#include "core/wav.h"
#include "dsp/hall_reverb.h"

KE_API int ke_reverb_render_wav(const char* input_wav, const char* output_wav, float mix, float tail_seconds) {
    if (!input_wav || !output_wav) return ke::fail(KE_ERR_INVALID_ARG, "null path");
    if (!(mix >= 0.f && mix <= 1.f)) return ke::fail(KE_ERR_INVALID_ARG, "reverb mix out of range");
    if (!(tail_seconds >= 0.f && tail_seconds <= 10.f)) return ke::fail(KE_ERR_INVALID_ARG, "tail out of range");
    ke::AudioBuffer in;
    if (int rc = ke::read_wav(input_wav, in); rc != KE_OK) return rc;
    if (in.frames() == 0 || in.sample_rate <= 0) return ke::fail(KE_ERR_INVALID_ARG, "empty input: %s", input_wav);
    std::vector<float> mono = ke::to_mono(in);
    for (float& v : mono) v = std::clamp(v, -1.f, 1.f);
    int sr = in.sample_rate;
    if (sr > ke::HallReverb::kMaxSampleRate) {
        mono = ke::resample(mono, sr, ke::HallReverb::kMaxSampleRate);
        sr = ke::HallReverb::kMaxSampleRate;
    }
    const size_t n = mono.size();
    const size_t total = n + static_cast<size_t>(std::lround(double(tail_seconds) * sr));
    mono.resize(total, 0.f);

    ke::AudioBuffer out;
    out.sample_rate = sr;
    out.channels = 2;
    out.planes.assign(2, std::vector<float>(total, 0.f));
    ke::HallReverb reverb(sr);
    std::vector<float> wl(ke::HallReverb::kBlock), wr(ke::HallReverb::kBlock);
    const float dg = ke::reverb_dry_gain(mix), wg = ke::reverb_wet_gain(mix);
    for (size_t done = 0; done < total;) {
        const int k = static_cast<int>(std::min<size_t>(ke::HallReverb::kBlock, total - done));
        reverb.process_wet(mono.data() + done, wl.data(), wr.data(), k);
        for (int i = 0; i < k; ++i) {
            const float d = mono[done + i] * dg;
            out.planes[0][done + i] = d + wl[i] * wg;
            out.planes[1][done + i] = d + wr[i] * wg;
        }
        done += static_cast<size_t>(k);
    }
    return ke::write_wav_f32(output_wav, out);
}
