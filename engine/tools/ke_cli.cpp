// Developer CLI for the engine. Every subcommand maps 1:1 onto the C API so
// numerical tests and CI can exercise the engine without Flutter.
//
//   ke_cli gpu
//   ke_cli runtime   --ort <lib> [--ep cpu|cuda|directml|coreml] [--device N] [--model <onnx>]
//   ke_cli separate  --ort <lib> [--ep ..] --model <onnx> --params '<json>' --in a.wav --primary p.wav [--secondary s.wav]
//   ke_cli transcribe --ort <lib> [--ep ..] --model-dir <dir> --in vocals.wav [--options '<json>'] --out notes.json
//   ke_cli beats     --ort <lib> [--ep ..] --model <beat-this dir> --in a.wav --out beats.json
//   ke_cli f0        --ort <lib> [--ep ..] --model <swiftf0.onnx> --in a.wav --out f0.json [--fmin f] [--fmax f]
//   ke_cli devices
//   ke_cli live      --ort <lib> --model <swiftf0.onnx> [--track a.wav] [--seconds 10]  (prints F0 frames)
//                    [--mode 0|1|2] [--pitch semitones] [--volume g] [--seek s] [--latency s] [--save take.wav]
//                    [--capture <id>] [--playback <id>] [--rate 48000]
//   ke_cli calibrate [--capture <id>] [--playback <id>] [--rate 48000]
#include <chrono>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <thread>
#include <vector>

#include "karaoke_engine.h"

namespace {

std::map<std::string, std::string> parse_args(int argc, char** argv, int start) {
    std::map<std::string, std::string> m;
    for (int i = start; i < argc; ++i) {
        std::string a = argv[i];
        if (a.rfind("--", 0) == 0) {
            std::string key = a.substr(2);
            if (i + 1 < argc && std::string(argv[i + 1]).rfind("--", 0) != 0) m[key] = argv[++i];
            else m[key] = "1";
        }
    }
    return m;
}

int ep_from_string(const std::string& s) {
    if (s == "cuda") return KE_EP_CUDA;
    if (s == "directml" || s == "dml") return KE_EP_DIRECTML;
    if (s == "coreml") return KE_EP_COREML;
    return KE_EP_CPU;
}

int progress_cb(float fraction, const char* stage, void*) {
    fprintf(stderr, "\r[%-10s] %5.1f%%", stage, fraction * 100.f);
    fflush(stderr);
    return 0;
}

std::string get_string(int (*fn)(char*, size_t, size_t*)) {
    size_t needed = 0;
    fn(nullptr, 0, &needed);
    std::string s(needed, '\0');
    fn(s.data(), needed, &needed);
    s.resize(needed ? needed - 1 : 0);
    return s;
}

void log_cb(int level, const char* msg, void*) {
    static const char* n[] = {"D", "I", "W", "E"};
    fprintf(stderr, "[%s] %s\n", n[level & 3], msg);
}

ke_runtime* make_runtime(const std::map<std::string, std::string>& a) {
    auto it = a.find("ort");
    if (it == a.end()) { fprintf(stderr, "--ort <path to onnxruntime library> is required\n"); return nullptr; }
    int ep = ep_from_string(a.count("ep") ? a.at("ep") : "cpu");
    int device = a.count("device") ? atoi(a.at("device").c_str()) : 0;
    int threads = a.count("threads") ? atoi(a.at("threads").c_str()) : 0;
    ke_runtime* rt = nullptr;
    int rc = ke_runtime_create(it->second.c_str(), ep, device, threads, &rt);
    if (rc != KE_OK) { fprintf(stderr, "runtime error %d: %s\n", rc, ke_last_error()); return nullptr; }
    return rt;
}

int usage() {
    fprintf(stderr, "ke_cli %s\nusage: ke_cli <gpu|runtime|separate|transcribe|beats|f0|reverb|devices|live|calibrate> [--options]\n", ke_version());
    return 2;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) return usage();
    std::string cmd = argv[1];
    auto a = parse_args(argc, argv, 2);
    if (a.count("verbose")) ke_set_log_callback(log_cb, nullptr);

    if (cmd == "gpu") {
        printf("%s\n", get_string(ke_system_gpu_info_json).c_str());
        return 0;
    }
    if (cmd == "devices") {
        printf("%s\n", get_string(ke_audio_list_devices_json).c_str());
        return 0;
    }
    if (cmd == "runtime") {
        ke_runtime* rt = make_runtime(a);
        if (!rt) return 1;
        size_t needed = 0;
        ke_runtime_info_json(rt, nullptr, 0, &needed);
        std::string info(needed, '\0');
        ke_runtime_info_json(rt, info.data(), needed, &needed);
        printf("%s\n", info.c_str());
        double ms = 0;
        int rc = ke_runtime_selftest(rt, a.count("model") ? a.at("model").c_str() : nullptr, &ms);
        printf("selftest: %s (%.1f ms)%s%s\n", rc == KE_OK ? "ok" : "FAILED", ms, rc == KE_OK ? "" : " ", rc == KE_OK ? "" : ke_last_error());
        ke_runtime_destroy(rt);
        return rc == KE_OK ? 0 : 1;
    }
    if (cmd == "separate") {
        ke_runtime* rt = make_runtime(a);
        if (!rt) return 1;
        auto t0 = std::chrono::steady_clock::now();
        int rc = ke_separate(rt, a["model"].c_str(), a.count("params") ? a["params"].c_str() : "{}",
                             a["in"].c_str(), a.count("primary") ? a["primary"].c_str() : nullptr,
                             a.count("secondary") ? a["secondary"].c_str() : nullptr, progress_cb, nullptr);
        auto t1 = std::chrono::steady_clock::now();
        fprintf(stderr, "\n");
        if (rc != KE_OK) { fprintf(stderr, "separate error %d: %s\n", rc, ke_last_error()); ke_runtime_destroy(rt); return 1; }
        printf("separate ok in %.1fs\n", std::chrono::duration<double>(t1 - t0).count());
        ke_runtime_destroy(rt);
        return 0;
    }
    if (cmd == "transcribe") {
        ke_runtime* rt = make_runtime(a);
        if (!rt) return 1;
        auto t0 = std::chrono::steady_clock::now();
        int rc = ke_transcribe(rt, a["model-dir"].c_str(), a["in"].c_str(),
                               a.count("options") ? a["options"].c_str() : "{}", a["out"].c_str(), progress_cb, nullptr);
        auto t1 = std::chrono::steady_clock::now();
        fprintf(stderr, "\n");
        if (rc != KE_OK) { fprintf(stderr, "transcribe error %d: %s\n", rc, ke_last_error()); ke_runtime_destroy(rt); return 1; }
        printf("transcribe ok in %.1fs -> %s\n", std::chrono::duration<double>(t1 - t0).count(), a["out"].c_str());
        ke_runtime_destroy(rt);
        return 0;
    }
    if (cmd == "beats") {
        ke_runtime* rt = make_runtime(a);
        if (!rt) return 1;
        auto t0 = std::chrono::steady_clock::now();
        int rc = ke_beats(rt, a["model"].c_str(), a["in"].c_str(), a["out"].c_str(), progress_cb, nullptr);
        auto t1 = std::chrono::steady_clock::now();
        fprintf(stderr, "\n");
        if (rc != KE_OK) { fprintf(stderr, "beats error %d: %s\n", rc, ke_last_error()); ke_runtime_destroy(rt); return 1; }
        printf("beats ok in %.2fs -> %s\n", std::chrono::duration<double>(t1 - t0).count(), a["out"].c_str());
        ke_runtime_destroy(rt);
        return 0;
    }
    if (cmd == "reverb") {
        // ke_cli reverb --in voice.wav --out wet.wav [--mix 0.3] [--tail 4]
        const float mix = a.count("mix") ? static_cast<float>(atof(a["mix"].c_str())) : 0.3f;
        const float tail = a.count("tail") ? static_cast<float>(atof(a["tail"].c_str())) : 4.f;
        auto t0 = std::chrono::steady_clock::now();
        int rc = ke_reverb_render_wav(a["in"].c_str(), a["out"].c_str(), mix, tail);
        auto t1 = std::chrono::steady_clock::now();
        if (rc != KE_OK) { fprintf(stderr, "reverb error %d: %s\n", rc, ke_last_error()); return 1; }
        printf("reverb ok in %.3fs -> %s\n", std::chrono::duration<double>(t1 - t0).count(), a["out"].c_str());
        return 0;
    }
    if (cmd == "f0") {
        ke_runtime* rt = make_runtime(a);
        if (!rt) return 1;
        float fmin = a.count("fmin") ? static_cast<float>(atof(a["fmin"].c_str())) : 46.875f;
        float fmax = a.count("fmax") ? static_cast<float>(atof(a["fmax"].c_str())) : 2093.75f;
        auto t0 = std::chrono::steady_clock::now();
        int rc = ke_f0_extract(rt, a["model"].c_str(), a["in"].c_str(), fmin, fmax, a["out"].c_str(), progress_cb, nullptr);
        auto t1 = std::chrono::steady_clock::now();
        fprintf(stderr, "\n");
        if (rc != KE_OK) { fprintf(stderr, "f0 error %d: %s\n", rc, ke_last_error()); ke_runtime_destroy(rt); return 1; }
        printf("f0 ok in %.2fs -> %s\n", std::chrono::duration<double>(t1 - t0).count(), a["out"].c_str());
        ke_runtime_destroy(rt);
        return 0;
    }
    if (cmd == "live" || cmd == "calibrate") {
        ke_audio* au = nullptr;
        int sr = a.count("rate") ? atoi(a["rate"].c_str()) : 48000;
        int rc = ke_audio_create(a.count("capture") ? a["capture"].c_str() : nullptr,
                                 a.count("playback") ? a["playback"].c_str() : nullptr, sr, &au);
        if (rc != KE_OK) { fprintf(stderr, "audio error %d: %s\n", rc, ke_last_error()); return 1; }
        if (cmd == "calibrate") {
            double rt_s = 0;
            rc = ke_audio_calibrate_latency(au, &rt_s);
            if (rc != KE_OK) fprintf(stderr, "calibrate error %d: %s\n", rc, ke_last_error());
            else printf("roundtrip latency: %.1f ms\n", rt_s * 1000.0);
            ke_audio_destroy(au);
            return rc == KE_OK ? 0 : 1;
        }
        ke_runtime* rt = nullptr;
        if (a.count("ort") && a.count("model")) rt = make_runtime(a);
        int mode = a.count("mode") ? atoi(a["mode"].c_str()) : (rt ? 2 : 0);
        if (a.count("track")) {
            rc = ke_audio_load_track(au, a["track"].c_str());
            if (rc != KE_OK) { fprintf(stderr, "load_track error: %s\n", ke_last_error()); return 1; }
            if (a.count("pitch")) ke_audio_set_pitch_shift(au, static_cast<float>(atof(a["pitch"].c_str())));
            if (a.count("volume")) ke_audio_set_volume(au, static_cast<float>(atof(a["volume"].c_str())));
            if (a.count("seek")) ke_audio_seek(au, atof(a["seek"].c_str()));
            fprintf(stderr, "track: %.3f s, position after setup %.3f s\n", ke_audio_track_duration(au), ke_audio_position(au));
        }
        if (a.count("latency")) ke_audio_set_latency_compensation(au, atof(a["latency"].c_str()));
        {
            double lin = 0, lout = 0;
            ke_audio_get_latency(au, &lin, &lout);
            fprintf(stderr, "device latency: input %.1f ms, output %.1f ms\n", lin * 1000.0, lout * 1000.0);
        }
        rc = ke_audio_start_capture(au, rt, rt ? a["model"].c_str() : nullptr, mode);
        if (rc != KE_OK) { fprintf(stderr, "start_capture error %d: %s\n", rc, ke_last_error()); return 1; }
        if (a.count("track")) ke_audio_play(au);
        double seconds = a.count("seconds") ? atof(a["seconds"].c_str()) : 10.0;
        std::vector<float> frames(5 * 512);
        auto start = std::chrono::steady_clock::now();
        while (std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count() < seconds) {
            int n = ke_audio_read_f0(au, frames.data(), 512);
            for (int i = 0; i < n; ++i) {
                const float* f = &frames[i * 5];
                printf("%8.3f  f0=%7.2f  conf=%.2f  rms=%6.1f dB  src=%d  pos=%.3f\n", f[0], f[1], f[2], f[3], (int)f[4], ke_audio_position(au));
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
        fprintf(stderr, "capture elapsed %.3f s, position %.3f s, playing %d, input level %.1f dBFS\n",
                ke_audio_capture_elapsed(au), ke_audio_position(au), ke_audio_is_playing(au), ke_audio_input_level_db(au));
        ke_audio_stop_capture(au);
        if (a.count("save")) {
            rc = ke_audio_save_capture(au, a["save"].c_str());
            if (rc != KE_OK) fprintf(stderr, "save_capture error %d: %s\n", rc, ke_last_error());
        }
        ke_audio_destroy(au);
        if (rt) ke_runtime_destroy(rt);
        return 0;
    }
    return usage();
}
