// Development tool: runs the live onset detector over raw mono float32 PCM on
// stdin and prints one onset time (seconds) per line. Used to tune
// src/dsp/onset.cpp against GAME note onsets (see tests/audio/onset_eval.py).
//   ffmpeg -i vocals.wav -ac 1 -ar 48000 -f f32le - | ke_onset_eval 48000 [delta] [floor_db] [combine_s] [frames]
// With `frames`, every frame is printed as "time onset(0/1) rms_db".
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "dsp/onset.h"

int main(int argc, char** argv) {
    const int sr = argc > 1 ? std::atoi(argv[1]) : 48000;
    ke::dsp::OnsetDetector det(sr);
    if (argc > 2) det.delta = static_cast<float>(std::atof(argv[2]));
    if (argc > 3) det.floor_db = static_cast<float>(std::atof(argv[3]));
    if (argc > 4) det.combine_s = std::atof(argv[4]);
    const bool all = argc > 5;
    std::vector<float> buf(4096);
    size_t n;
    while ((n = std::fread(buf.data(), sizeof(float), buf.size(), stdin)) > 0) {
        det.feed(buf.data(), n, [&](const ke::dsp::OnsetDetector::Frame& f) {
            if (all) std::printf("%.4f %d %.1f\n", double(f.centre) / sr, f.onset ? 1 : 0, f.rms_db);
            else if (f.onset) std::printf("%.4f\n", double(f.centre) / sr);
        });
    }
    return 0;
}
