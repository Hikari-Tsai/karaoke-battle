// GAME (openvpi) singing transcription. See docs/ARCHITECTURE.md §GAME.
#pragma once
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "karaoke_engine.h"

namespace ke {
class OrtSession;
}

namespace ke::game {

struct Note {
    double onset = 0;    // seconds from file start
    double offset = 0;
    float pitch = 0;     // MIDI number, fractional
};

struct Options {
    int language_id = 0;           // from config.json languages map (0 = unknown)
    float seg_threshold = 0.2f;
    float seg_radius_seconds = 0.02f;
    float t0 = 0.0f;
    int nsteps = 8;
    float est_threshold = 0.2f;
    // slicer
    float slicer_threshold_db = -40.f;
    int slicer_min_length_ms = 1000;
    int slicer_min_interval_ms = 200;
    int slicer_hop_ms = 20;
    int slicer_max_sil_kept_ms = 100;
    double max_chunk_seconds = 40.0;   // hard cap; longer slices are split at their quietest point
};

// The five ONNX sessions plus config.json. Kept in one struct so a caller can
// keep GAME loaded between calls (loading ~400 MB of weights is the slow part).
struct Model {
    std::string model_dir;
    std::string name;                       // basename of model_dir
    int samplerate = 44100;
    double timestep = 0.01;
    std::map<std::string, int> languages;   // name -> id (0 = unknown / universal)
    bool loop = true;
    std::unique_ptr<OrtSession> encoder, segmenter, estimator, dur2bd, bd2dur;

    Model();
    ~Model();
    Model(const Model&) = delete;
    Model& operator=(const Model&) = delete;

    // Reads config.json and creates the five sessions. Returns nullptr and sets
    // ke_last_error (and *error) on failure.
    static std::unique_ptr<Model> load(ke_runtime* rt, const std::string& model_dir, std::string* error);

    // Language name -> id via config.json. Unknown or empty -> 0.
    int language_id(const std::string& name) const;

    // Runs the per-slice pipeline on one mono chunk at the model sample rate.
    // `offset_seconds` is added to the note times. Appends to `notes` the raw
    // (unsorted, possibly overlapping across slices) notes of this chunk.
    int run_chunk(const float* wav, size_t n, double offset_seconds, const Options& opt,
                  std::vector<Note>& notes, ke_progress_cb progress, void* user,
                  float progress_begin, float progress_end);
};

// Reads config.json of model_dir only (no sessions), used by parse_options.
int read_model_config(const std::string& model_dir, Model& out);

// Parses options JSON (see karaoke_engine.h ke_transcribe). Unknown keys are
// ignored; nlohmann exceptions are caught and turned into KE_ERR_INVALID_ARG.
// language_name receives the "language" string of the JSON (may be empty).
int parse_options(const std::string& json, const std::string& model_dir, Options& out, std::string* language_name);

int transcribe(ke_runtime* rt, const std::string& model_dir, const std::string& input_wav,
               const std::string& options_json, const std::string& notes_out_json,
               ke_progress_cb progress, void* user);

// Lower level: transcribe an in-memory mono waveform at the model sample rate
// (44.1 kHz). Loads the model from model_dir.
int transcribe_waveform(ke_runtime* rt, const std::string& model_dir, const std::vector<float>& mono44k,
                        const Options& opt, std::vector<Note>& notes, ke_progress_cb progress, void* user);

// Same with an already loaded model.
int transcribe_waveform(Model& model, const std::vector<float>& mono44k, const Options& opt,
                        std::vector<Note>& notes, ke_progress_cb progress, void* user);

// Sorts by (onset, offset, pitch) and enforces monotonic non-overlapping notes
// exactly like SaveCombinedFileCallback.save_file().
void merge_notes(std::vector<Note>& notes);

// Serialises the result JSON ({"timestep","language","model","notes":[...]}).
std::string notes_to_json(const std::vector<Note>& notes, double timestep, const std::string& language,
                          const std::string& model_name);

}  // namespace ke::game
