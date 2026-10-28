#include "core/wav.h"

#include "core/error.h"
#include "dr_libs/dr_wav.h"

namespace ke {

int read_wav(const std::string& path, AudioBuffer& out) {
    drwav wav;
    if (!drwav_init_file(&wav, path.c_str(), nullptr)) {
        return fail(KE_ERR_IO, "cannot open WAV: %s", path.c_str());
    }
    out.sample_rate = static_cast<int>(wav.sampleRate);
    out.channels = static_cast<int>(wav.channels);
    const drwav_uint64 total = wav.totalPCMFrameCount;
    std::vector<float> inter(static_cast<size_t>(total * wav.channels));
    drwav_uint64 got = drwav_read_pcm_frames_f32(&wav, total, inter.data());
    drwav_uninit(&wav);
    out.planes.assign(out.channels, std::vector<float>(static_cast<size_t>(got)));
    for (drwav_uint64 i = 0; i < got; ++i) {
        for (int c = 0; c < out.channels; ++c) {
            out.planes[c][static_cast<size_t>(i)] = inter[static_cast<size_t>(i * wav.channels + c)];
        }
    }
    return KE_OK;
}

int write_wav_f32(const std::string& path, const AudioBuffer& buf) {
    drwav_data_format fmt;
    fmt.container = drwav_container_riff;
    fmt.format = DR_WAVE_FORMAT_IEEE_FLOAT;
    fmt.channels = static_cast<drwav_uint32>(buf.channels);
    fmt.sampleRate = static_cast<drwav_uint32>(buf.sample_rate);
    fmt.bitsPerSample = 32;
    drwav wav;
    if (!drwav_init_file_write(&wav, path.c_str(), &fmt, nullptr)) {
        return fail(KE_ERR_IO, "cannot create WAV: %s", path.c_str());
    }
    const size_t frames = buf.frames();
    std::vector<float> inter(frames * buf.channels);
    for (size_t i = 0; i < frames; ++i)
        for (int c = 0; c < buf.channels; ++c)
            inter[i * buf.channels + c] = buf.planes[c][i];
    drwav_uint64 written = drwav_write_pcm_frames(&wav, frames, inter.data());
    drwav_uninit(&wav);
    if (written != frames) return fail(KE_ERR_IO, "short write to WAV: %s", path.c_str());
    return KE_OK;
}

std::vector<float> to_mono(const AudioBuffer& buf) {
    std::vector<float> m(buf.frames(), 0.f);
    if (buf.channels == 0) return m;
    const float g = 1.0f / buf.channels;
    for (int c = 0; c < buf.channels; ++c)
        for (size_t i = 0; i < m.size(); ++i) m[i] += buf.planes[c][i] * g;
    return m;
}

AudioBuffer with_channels(const AudioBuffer& buf, int channels) {
    if (buf.channels == channels) return buf;
    AudioBuffer out;
    out.sample_rate = buf.sample_rate;
    out.channels = channels;
    if (channels == 1) {
        out.planes.push_back(to_mono(buf));
    } else {
        std::vector<float> mono = buf.channels == 1 ? buf.planes[0] : to_mono(buf);
        for (int c = 0; c < channels; ++c) out.planes.push_back(c < buf.channels ? buf.planes[c] : mono);
    }
    return out;
}

}  // namespace ke
