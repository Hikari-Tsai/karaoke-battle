// Backing-track alignment (ke_align_backing_wav), see dsp/align.h.
#include "karaoke_engine.h"

#include <cstdio>
#include <string>

#include "core/error.h"
#include "core/resample.h"
#include "core/wav.h"
#include "dsp/align.h"

namespace {
constexpr int kAlignRate = 8000;

int load_mono_8k(const char* path, std::vector<float>& out) {
    ke::AudioBuffer buf;
    if (int rc = ke::read_wav(path, buf); rc != KE_OK) return rc;
    if (buf.frames() == 0 || buf.sample_rate <= 0) return ke::fail(KE_ERR_INVALID_ARG, "empty audio: %s", path);
    out = ke::resample(ke::to_mono(buf), buf.sample_rate, kAlignRate);
    return KE_OK;
}
}  // namespace

KE_API int ke_align_backing_wav(const char* mix_wav, const char* backing_wav, const char* out_json) {
    if (!mix_wav || !backing_wav || !out_json) return ke::fail(KE_ERR_INVALID_ARG, "null path");
    std::vector<float> mix, backing;
    if (int rc = load_mono_8k(mix_wav, mix); rc != KE_OK) return rc;
    if (int rc = load_mono_8k(backing_wav, backing); rc != KE_OK) return rc;
    const auto r = ke::align::align_backing(mix, backing, kAlignRate);
    FILE* f = fopen(out_json, "wb");
    if (!f) return ke::fail(KE_ERR_IO, "cannot write %s", out_json);
    const std::string json = ke::align::to_json(r);
    fwrite(json.data(), 1, json.size(), f);
    fclose(f);
    return KE_OK;
}
