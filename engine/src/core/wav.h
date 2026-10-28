// WAV I/O (dr_wav) with float planar buffers.
#pragma once
#include <string>
#include <vector>

namespace ke {

struct AudioBuffer {
    int sample_rate = 0;
    int channels = 0;
    std::vector<std::vector<float>> planes;   // planes[channel][frame]
    size_t frames() const { return planes.empty() ? 0 : planes[0].size(); }
    double duration() const { return sample_rate ? double(frames()) / sample_rate : 0.0; }
};

// Reads any PCM/float WAV. Returns KE_OK or error (ke_last_error set).
int read_wav(const std::string& path, AudioBuffer& out);
// Writes 32-bit float WAV.
int write_wav_f32(const std::string& path, const AudioBuffer& buf);
// Mix down to mono (average of channels).
std::vector<float> to_mono(const AudioBuffer& buf);
// Returns a buffer with exactly `channels` channels (mono->dup, stereo->avg).
AudioBuffer with_channels(const AudioBuffer& buf, int channels);

}  // namespace ke
