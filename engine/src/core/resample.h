// High quality resampling (windowed-sinc, polyphase-free direct form).
// Used for 44.1k -> 16k (SwiftF0) and arbitrary input rates -> 44.1k.
#pragma once
#include <vector>

namespace ke {

// Resamples one channel. Quality is sufficient for model input (-90 dB stopband).
std::vector<float> resample(const std::vector<float>& in, int in_rate, int out_rate);

}  // namespace ke
