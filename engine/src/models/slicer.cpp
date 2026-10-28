#include "models/slicer.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <utility>

namespace ke::game {

long long py_round(double x) {
    // std::nearbyint uses the current rounding mode, FE_TONEAREST by default
    // (ties to even), which is exactly Python's round() for floats.
    return static_cast<long long>(std::nearbyint(x));
}

bool validate_slicer_params(const SlicerParams& p, std::string* why) {
    if (p.sr <= 0) { if (why) *why = "slicer sample rate must be positive"; return false; }
    if (p.hop_ms <= 0) { if (why) *why = "slicer hop_ms must be positive"; return false; }
    if (!(p.min_length_ms >= p.min_interval_ms && p.min_interval_ms >= p.hop_ms)) {
        if (why) *why = "slicer: the following condition must be satisfied: min_length >= min_interval >= hop_size";
        return false;
    }
    if (!(p.max_sil_kept_ms >= p.hop_ms)) {
        if (why) *why = "slicer: the following condition must be satisfied: max_sil_kept >= hop_size";
        return false;
    }
    return true;
}

SlicerFrames resolve_slicer_frames(const SlicerParams& p) {
    // Mirrors Slicer.__init__ (Python float arithmetic + round()).
    SlicerFrames f;
    const double sr = p.sr;
    const double min_interval = sr * p.min_interval_ms / 1000.0;
    f.threshold = std::pow(10.0, p.threshold_db / 20.0);
    f.hop_size = static_cast<int>(py_round(sr * p.hop_ms / 1000.0));
    f.win_size = static_cast<int>(std::min<long long>(py_round(min_interval), 4LL * f.hop_size));
    f.min_length = static_cast<int>(py_round(sr * p.min_length_ms / 1000.0 / f.hop_size));
    f.min_interval = static_cast<int>(py_round(min_interval / f.hop_size));
    f.max_sil_kept = static_cast<int>(py_round(sr * p.max_sil_kept_ms / 1000.0 / f.hop_size));
    if (f.hop_size < 1) f.hop_size = 1;
    if (f.win_size < 1) f.win_size = 1;
    return f;
}

std::vector<float> get_rms(const std::vector<float>& y, int frame_length, int hop_length) {
    std::vector<float> out;
    if (frame_length <= 0 || hop_length <= 0) return out;
    const long long L = static_cast<long long>(y.size());
    const long long pad = frame_length / 2;
    const long long n_padded = L + 2 * pad;
    const long long usable = n_padded - frame_length + 1;   // number of window start positions
    if (usable <= 0) return out;
    const long long n_frames = (usable + hop_length - 1) / hop_length;
    out.resize(static_cast<size_t>(n_frames));
    for (long long i = 0; i < n_frames; ++i) {
        const long long start = i * hop_length - pad;        // index in the unpadded signal
        const long long j0 = std::max<long long>(0, start);
        const long long j1 = std::min<long long>(L, start + frame_length);
        double acc = 0.0;
        for (long long j = j0; j < j1; ++j) {
            const double v = y[static_cast<size_t>(j)];
            acc += v * v;
        }
        out[static_cast<size_t>(i)] = static_cast<float>(std::sqrt(acc / frame_length));
    }
    return out;
}

namespace {

// np.argmin over rms[lo:hi] (clipped like a Python slice); returns the absolute
// index of the first minimum. Requires a non-empty range.
long long argmin_range(const std::vector<float>& rms, long long lo, long long hi) {
    const long long n = static_cast<long long>(rms.size());
    lo = std::max<long long>(0, lo);
    hi = std::min<long long>(n, hi);
    long long best = lo;
    for (long long i = lo + 1; i < hi; ++i) {
        if (rms[static_cast<size_t>(i)] < rms[static_cast<size_t>(best)]) best = i;
    }
    return best;
}

Slice apply_slice(size_t total_samples, long long begin_frame, long long end_frame, int hop) {
    Slice s;
    const long long b = begin_frame * hop;
    const long long e = end_frame * hop;
    s.begin = static_cast<size_t>(std::max<long long>(0, b));
    s.end = static_cast<size_t>(std::min<long long>(static_cast<long long>(total_samples), e));
    if (s.end < s.begin) s.end = s.begin;
    return s;
}

}  // namespace

std::vector<Slice> slice_waveform(const std::vector<float>& mono, const SlicerParams& p) {
    std::vector<Slice> result;
    const size_t L = mono.size();
    if (L == 0) return result;
    const SlicerFrames f = resolve_slicer_frames(p);
    const int hop = f.hop_size;

    if (static_cast<long long>((L + hop - 1) / hop) <= f.min_length) {
        result.push_back(Slice{0, L});
        return result;
    }
    const std::vector<float> rms_list = get_rms(mono, f.win_size, hop);
    const long long total_frames = static_cast<long long>(rms_list.size());

    std::vector<std::pair<long long, long long>> sil_tags;
    long long silence_start = -1;   // -1 == None
    long long clip_start = 0;
    for (long long i = 0; i < total_frames; ++i) {
        const double rms = rms_list[static_cast<size_t>(i)];
        // Keep looping while frame is silent.
        if (rms < f.threshold) {
            if (silence_start < 0) silence_start = i;
            continue;
        }
        // Keep looping while frame is not silent and silence start has not been recorded.
        if (silence_start < 0) continue;
        // Clear recorded silence start if interval is not enough or clip is too short.
        const bool is_leading_silence = silence_start == 0 && i > f.max_sil_kept;
        const bool need_slice_middle = (i - silence_start >= f.min_interval) && (i - clip_start >= f.min_length);
        if (!is_leading_silence && !need_slice_middle) {
            silence_start = -1;
            continue;
        }
        // Need slicing. Record the range of silent frames to be removed.
        if (i - silence_start <= f.max_sil_kept) {
            const long long pos = argmin_range(rms_list, silence_start, i + 1);
            if (silence_start == 0) sil_tags.emplace_back(0, pos);
            else sil_tags.emplace_back(pos, pos);
            clip_start = pos;
        } else if (i - silence_start <= 2LL * f.max_sil_kept) {
            const long long pos = argmin_range(rms_list, i - f.max_sil_kept, silence_start + f.max_sil_kept + 1);
            const long long pos_l = argmin_range(rms_list, silence_start, silence_start + f.max_sil_kept + 1);
            const long long pos_r = argmin_range(rms_list, i - f.max_sil_kept, i + 1);
            if (silence_start == 0) {
                sil_tags.emplace_back(0, pos_r);
                clip_start = pos_r;
            } else {
                sil_tags.emplace_back(std::min(pos_l, pos), std::max(pos_r, pos));
                clip_start = std::max(pos_r, pos);
            }
        } else {
            const long long pos_l = argmin_range(rms_list, silence_start, silence_start + f.max_sil_kept + 1);
            const long long pos_r = argmin_range(rms_list, i - f.max_sil_kept, i + 1);
            if (silence_start == 0) sil_tags.emplace_back(0, pos_r);
            else sil_tags.emplace_back(pos_l, pos_r);
            clip_start = pos_r;
        }
        silence_start = -1;
    }
    // Deal with trailing silence.
    if (silence_start >= 0 && total_frames - silence_start >= f.min_interval) {
        const long long silence_end = std::min(total_frames, silence_start + f.max_sil_kept);
        const long long pos = argmin_range(rms_list, silence_start, silence_end + 1);
        sil_tags.emplace_back(pos, total_frames + 1);
    }
    // Apply and return slices.
    if (sil_tags.empty()) {
        result.push_back(Slice{0, L});
        return result;
    }
    auto push = [&](long long b, long long e) {
        Slice s = apply_slice(L, b, e, hop);
        if (s.end > s.begin) result.push_back(s);
    };
    if (sil_tags.front().first > 0) push(0, sil_tags.front().first);
    for (size_t i = 0; i + 1 < sil_tags.size(); ++i) push(sil_tags[i].second, sil_tags[i + 1].first);
    if (sil_tags.back().second < total_frames) push(sil_tags.back().second, total_frames);
    return result;
}

std::vector<Slice> split_long_slices(const std::vector<float>& mono, const std::vector<Slice>& slices,
                                     const SlicerFrames& frames, size_t max_samples,
                                     std::vector<float>* rms_cache) {
    std::vector<Slice> out;
    if (max_samples == 0) return slices;
    std::vector<float> local_rms;
    std::vector<float>* rms = rms_cache ? rms_cache : &local_rms;
    const int hop = std::max(1, frames.hop_size);

    for (const Slice& root : slices) {
        // Depth-first, left part first, so the output stays sorted.
        std::vector<Slice> stack{root};
        while (!stack.empty()) {
            Slice s = stack.back();
            stack.pop_back();
            const size_t len = s.length();
            if (len <= max_samples) {
                if (len > 0) out.push_back(s);
                continue;
            }
            if (rms->empty()) *rms = get_rms(mono, frames.win_size, hop);
            // Candidate frames whose centre sample lies in the central half of the slice.
            const long long lo_sample = static_cast<long long>(s.begin + len / 4);
            const long long hi_sample = static_cast<long long>(s.end - len / 4);
            long long f0 = (lo_sample + hop - 1) / hop;      // first frame with i*hop >= lo
            long long f1 = hi_sample / hop;                  // last frame with i*hop <= hi
            f1 = std::min<long long>(f1, static_cast<long long>(rms->size()) - 1);
            size_t split;
            if (f1 >= f0 && f0 >= 0) {
                const long long best = argmin_range(*rms, f0, f1 + 1);
                split = static_cast<size_t>(best * hop);
            } else {
                split = s.begin + len / 2;
            }
            if (split <= s.begin || split >= s.end) split = s.begin + len / 2;
            // Push right first so the left part is processed next.
            stack.push_back(Slice{split, s.end});
            stack.push_back(Slice{s.begin, split});
        }
    }
    return out;
}

}  // namespace ke::game
