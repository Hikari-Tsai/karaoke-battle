# Scoring Algorithm

[中文](SCORING.md) · **English** · [日本語](SCORING.ja.md)

This document explains how Karaoke Battle compares a take against the reference data and scores it. The implementation lives in
[`app/lib/scoring/`](../app/lib/scoring/) (pure Dart, no Flutter dependency), and the entry point is
`Scorer.score(ScoringInput) -> ScoreResult`. Every numeric constant can be overridden through `ScoringOptions` and
`ScoringWeights`; the values listed below are the defaults.

## 1. Inputs

| Data | Source | Contents |
| --- | --- | --- |
| Reference notes `notes.json` | GAME transcription of the separated vocals | Onset and offset (seconds) and MIDI pitch (float, may be fractional) for each note |
| Reference F0 curve `ref_f0.json` | SwiftF0 on the separated vocals | One F0 every 16 ms (Hz, 0 = unvoiced) with a confidence value |
| Take F0 curve `take_f0.json` | SwiftF0 on the recorded microphone audio | Same as above |
| Energy curves (optional) | RMS of take.wav and vocals.wav | One dB value every 16 ms, used for expression |

Scoring uses only the pitch and energy above and **does not recognise the lyrics**: wrong words, or humming through a forgotten line, cost nothing as long as the pitch and timing are right (the song's language only affects how accurately the GAME model detects the notes).

F0 is first converted to semitones (MIDI float): `midi = 69 + 12·log2(f0 / 440)`. Frames with confidence below 0.4 are treated as unvoiced.
Both curves are resampled onto the same 16 ms grid. When a reference F0 curve is available, each frame has two targets:
**the original singer's curve** (including vibrato and slides) and **the GAME note pitch**; the take counts as correct if it matches either one.
So following the original singer's slides counts as correct, and singing the note straight and holding the note pitch also counts as correct. Without a reference curve, only the note pitch sampled on the grid is used.
The two targets cover for each other's errors: when GAME mislabels a pitch, the original curve is still there; when the original singer's attack slides by more than a semitone, the note pitch is still there.

## 2. Octaves count as the same note, and a global transposition is allowed

This is a deliberate project design decision: singers can sing in whatever key and octave is comfortable for them.

* **Chroma distance**: when two pitches differ by `d` semitones, the distance is `min(|d| mod 12, 12 − |d| mod 12)`.
  Singing an octave higher or an octave lower is therefore identical to the original, with a distance of 0.
* **A single transposition k for the whole song**: among `k = 0..11`, the one that yields the highest Raw Chroma Accuracy is chosen,
  and the whole song uses that one k. Per-phrase changes are not allowed; otherwise any random singing could find local matches.
* An "octave-exact" transposition (−24..24 semitones) and its corresponding Raw Pitch Accuracy are also computed,
  **displayed only, not scored**, so users can tell whether they sang the entire song an octave low.
* The live coloring on the singing screen and the post-take scoring use the same chroma rules (`LiveComparator`).

## 3. Time alignment

1. **Coarse alignment**: cross-correlate the voiced/unvoiced indicators to find the global delay (within ±2 seconds).
2. **DTW fine alignment**: Sakoe-Chiba band of ±1 second, centered on the coarse-alignment diagonal.
   Local cost: 0 when both sides are unvoiced; 1 when one is voiced and the other unvoiced; `chroma distance / 6` when both are voiced.
   Off-diagonal steps incur an additional gap penalty of 0.5, which prevents a random take from "cherry-picking" scattered matching frames by warping time.
3. After alignment, k is re-estimated once to obtain the final value.
4. Rhythm judgements (4.4) **do not use DTW**: only the global delay is removed, so per-note timing errors are kept and judged. `AlignmentMode` affects pitch and the other items only.

## 4. Metrics

### 4.1 Frame level (mir_eval `melody` definitions, 50 cents tolerance)

| Metric | Definition |
| --- | --- |
| Raw Pitch Accuracy (RPA) | Among reference-voiced frames, the fraction where the take is voiced and `|take + shift − ref| ≤ 0.5` semitones (ref being either the original singer's curve or the note pitch) (display only) |
| Raw Chroma Accuracy (RCA) | Same as above but using chroma distance; **the primary pitch metric** |
| Voicing Recall | Fraction of reference-voiced frames in which the take is also voiced |
| Voicing False Alarm | Fraction of reference-unvoiced frames in which the take is voiced |
| Overall Accuracy | Fraction of frames where both sides are unvoiced, or both are voiced and the chroma is correct |

### 4.2 Note level (default: reference-note guided)

GAME splits notes by syllable, and consecutive syllables often share the same pitch, so segmenting by F0 alone would merge them. By default, notes are therefore not segmented from the take F0;
instead, **each reference note is evaluated within its own time range**:

* **Matching frame**: the take is voiced, and its chroma distance to the reference curve **or** the note pitch is ≤ 50 cents (in the extension zone outside the note's range, only the note pitch counts, so neighboring notes are not counted as this note).
* **Pitch hit**: matching frames cover ≥ 50% of the note's range.
* **Take onset / offset**: within `[onset − 100 ms, offset + 100 ms]`, find the matching segment that overlaps the note the most
  (allowing gaps of up to 3 frames); the segment's boundaries are the take's start and end. The search window extends only into rests,
  never into the range of adjacent notes (a slide between notes is a transition; entering the next note early shows up in the previous note's offset error).
* **Expected onset / offset**: when a reference curve is available, measured the same way on the original singer's curve, so the original singer singing it gets a perfect score.
* **Onset hit**: `|onset error| ≤ 50 ms`; **offset hit**: both onset and pitch are hits and
  `|offset error| ≤ max(50 ms, 20% × note length)`. These hits only feed the precision / recall / F1 diagnostics below; **the rhythm sub-score uses the tiered judgement in 4.4**.
* Notes in which the reference curve is entirely unvoiced are marked as not evaluable and excluded.
* The precision denominator includes "notes sung wrong or right" plus "take voiced segments that fall outside all notes" (false alarms).

The output consists of three sets of precision / recall / F1 (onset only, onset + pitch, and onset + pitch + offset),
plus a per-note report (hit or miss, median cents deviation, onset/offset error, coverage).
`NoteSegmentation.fromTakeF0` switches back to the mir_eval `transcription` approach: segmenting notes from the take F0 and then doing bipartite matching.

### 4.3 Technique metrics

These are analyzed only on **long tones** (reference notes ≥ 400 ms); the take side uses the raw frames without time warping.

* **Vibrato**: detrend the pitch curve, apply a Hann window, and compute a DFT from 3 to 9 Hz at 0.05 Hz resolution.
  An analysis window of about 0.5 seconds is judged to contain vibrato when: the rate is 4 to 8 Hz, the peak-to-peak extent is 30 to 150 cents,
  and the periodicity (sinusoid energy / detrended variance) is ≥ 0.35. Each long tone's "vibrato amount" = the fraction of analysis windows that pass.
* **Stability**: after filtering out vibrato with a moving average over one vibrato period (6 Hz is assumed when none is detected),
  the standard deviation (cents) of the pitch relative to its median. The same value is computed on the original singer's curve as a baseline.
* **Long tone**: within each long tone's range, the fraction of frames in which the take is voiced and within 50 cents of the target,
  counting only reference-voiced frames.
* **Expression**: the Pearson correlation coefficient between the take and reference energy curves (dB) over reference-voiced frames, after alignment.

### 4.4 Rhythm judgements (rhythm-game style)

Modelled on rhythm games such as maimai, CHUNITHM and Taiko no Tatsujin: each reference note's onset and offset error falls into a tier with a fixed credit.

| Judgement | Window (120 BPM) | Credit |
| --- | --- | --- |
| PERFECT | ±50 ms | 100% |
| GREAT | ±100 ms | 85% |
| GOOD | ±150 ms | 60% |
| MISS | beyond, or the note was not sung | 0% |

* **Tempo scaling**: windows are multiplied by `120 / BPM`, clamped to 0.75–1.5×, so faster songs are stricter and slower songs looser. The BPM is the user's manual setting, else the Beat This! detection; without either the 120 BPM windows apply.
* **Offsets**: the same tiers, widened for long notes to 20% / 40% / 60% of the note length (whichever is larger). No offset judgement when the onset is a MISS.
* **Per-note credit** = 0.7 × onset + 0.3 × offset; the rhythm sub-score is the mean over evaluable notes.
* **Alignment**: a single global offset, no DTW, so per-note deviations are not absorbed. With a measured latency (Settings, "Calibrate latency") the recording clock is trusted, so a take that is early or late as a whole counts too; if the estimated global offset exceeds ±150 ms the calibration is assumed stale (e.g. another device) and the estimate is used. Without a measured latency the estimate is always used.
* **Rushing / dragging**: the median onset error of hit notes; ≤ −25 ms is rushing, ≥ +25 ms is dragging, otherwise steady. Only shown when the recording clock is trusted (after the 走り / タメ meter of DAM's 精密採点).

#### Replay pop-ups (timing + pitch)

The pop-up shown at each note's onset in the replay looks at timing and pitch together and **shows the lower of the two tiers**, so a note that is on time but off key cannot show PERFECT:

| Pop-up | Timing (onset judgement, table above) | Pitch (median deviation of the note) |
| --- | --- | --- |
| PERFECT | PERFECT | within ±15 cents |
| GREAT | GREAT | within ±30 cents |
| GOOD | GOOD | within ±50 cents |
| MISS | MISS | beyond ±50 cents |

* Pitch deviation: for every voiced take frame in the note's span, the chroma deviation from the reference curve or the note pitch, whichever is closer (octaves ignored, global transposition removed, as for the matching frames in 4.2); the pop-up uses the median, so a note that starts in tune and then drifts shows it too. A note that was not sung is judged on timing alone.
* Tags under the word say where the points went: **FAST** (early) or **LATE** (late) when the timing was GREAT / GOOD, and **HIGH** (sharp) or **LOW** (flat) when the pitch was off by more than ±20 cents.
* **Display only, scores are unchanged**: the rhythm sub-score still uses the timing judgements in the table above, and pitch is scored by the pitch sub-score (weight 40%).

#### Live pop-ups while singing

Pop-ups also appear live while recording (the star button at the top right of the singing screen turns them on or off; on by default). To keep the delay as short as possible they **judge onsets only**: PERFECT / GREAT / GOOD / MISS with FAST / LATE, without waiting for pitch, so there is no HIGH / LOW. The replay pop-ups are unchanged: they come from the score of the whole recording and weigh timing and pitch.

* **Onset source**: while recording, the engine runs an onset detector on the microphone: ~21 ms windows every 5 ms, log-magnitude spectral flux over 80 Hz–8 kHz (against the spectrum two hops back, max-filtered across neighbouring bins, so vibrato and slow swells do not count), with causal peak picking (0.06 above the mean of the last 0.1 s, the largest of the last 30 ms, at least −50 dB, onsets at least 60 ms apart). Reported times are moved 24 ms later: on separated vocals the detected onsets sit that much before GAME's note onsets (the consonant comes before the stable pitch). On the separated vocals of 5 songs, about 91% of GAME notes have a detected onset within ±120 ms, with a median error of 0 ms.
* **Onset**: each note searches one GOOD window either side of its onset, cut at the midpoints to the neighbouring notes' onsets so one sung onset is not claimed by two notes. The first onset in that range minus the note onset is the timing error.
* **Judgement time**: as soon as the onset arrives, so a pop-up comes up about one analysis window after the sound, plus the audio device's own latency. Over a BlackHole loopback (60 ms round trip) an onset reached the app about 66 ms after it was played; the old pitch-based judge needed about 0.18 s more.
* **No onset**: when the range closes without one, it is a MISS if the singer was silent there, and no pop-up if they kept singing (a note joined to the previous one without a new syllable). When frames arrive late it waits up to 0.6 s, and the pop-up plays its whole animation from the moment it is judged.
* They are live feedback for the singer; **the score still comes from the whole recording after the take**. On 18 real takes (2745 notes), 83% of notes got a pop-up; of those, about 75% had the same tier as the post-take onset judgement and about 88% were within one tier.

## 5. Sub-scores and total score

All sub-scores lie in `[0, 1]`, and all mappings are monotonic. `clamp` means clamping to `[0, 1]`.

| Sub-score | Formula | When not evaluable |
| --- | --- | --- |
| Pitch | `clamp((RCA − 0.15) / 0.6)` | Always evaluable |
| Rhythm | Mean over evaluable notes of `0.7·onset judgement + 0.3·offset judgement`, with PERFECT 1, GREAT 0.85, GOOD 0.6, MISS 0 (see 4.4) | No evaluable note → 0 |
| Stability | `clamp(1 − max(0, std − refStd) / 80)`, where std is the mean standard deviation over the take's long tones and refStd is the same value for the original singer | No long tones in the reference → excluded; no analyzable long tones in the take → 0 |
| Vibrato | `clamp(amount / target)`, where amount is the mean vibrato amount over the take's long tones, `target = min(original vibrato amount, 0.4)` | No long tones in the reference, or the original singer barely uses vibrato (amount < 0.25) → excluded |
| Expression | `clamp(r / 0.6)` | Either energy curve missing → excluded |
| Long tone | `clamp(mean achievement ratio over long tones / 0.8)` | No long tones in the reference → excluded |

Default weights: pitch 40, rhythm 20, stability 10, vibrato 10, expression 10, long tone 10.

```
raw   = 100 × Σ(wᵢ · sᵢ) / Σ(wᵢ)      summed only over "evaluable" sub-scores; weights are renormalized automatically
total = raw interpolated linearly between the knots in 5.1
```

| Total score | Rank |
| --- | --- |
| ≥ 98 | SSS |
| ≥ 95 | SS |
| ≥ 91 | S |
| ≥ 86 | A |
| ≥ 78 | B |
| ≥ 67 | C |
| Otherwise | D |

### 5.1 Score scale

The sub-scores were relaxed in v0.7.3 and the total curve was tightened at the top in v0.7.4: ordinary singing still scores, but good and great singing stay apart. The earlier scale aligned with DAM 精密採点 (`0.55 × raw + 45`) let almost nobody pass 90 in practice; v0.7.3's ease-out curve then packed every decent take between 87 and 97, with nothing to tell them apart.

1. **Sub-scores** (table above): pitch reaches full marks with 75% of frames in tune (was 95%); rhythm gives GREAT 85% and GOOD 60% (was 70% and 40%); stability tolerates 80 cents more wobble than the original singer (was 50); expression is full at correlation 0.6 (was 0.8); a long note held for 80% of its length counts as full.
2. **Total curve**: linear interpolation between the knots below. The low end is generous (a silent or random take stays near 0, a partly sung one gets the 60s); above raw 35 each raw point is worth 0.4 to 0.8, steeper towards the top, so good and great singing separate. S (91) needs raw about 88, SSS (98) needs raw 97.5.

| raw | 0 | 20 | 35 | 65 | 80 | 90 | 100 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Total | 0 | 56 | 68 | 80 | 87 | 92 | 100 |

| raw | 10 | 30 | 40 | 50 | 60 | 70 |
| --- | --- | --- | --- | --- | --- | --- |
| Total | 28 | 64.0 | 70.0 | 74.0 | 78.0 | 82.3 |

Calibrated on 18 real takes: the 5 with roughly 60%+ pitch accuracy and fair timing score 80.1 to 90.7 (B and A, about 7 below v0.7.3); the 5 that hit only a few notes sit at 63 to 67; silent or random takes stay at 52 or below, the same as v0.7.3. Rank thresholds are unchanged (98 / 95 / 91 / 86 / 78 / 67).

score.json stores `scale: 4`. Takes scored by older versions (`scale` 3, 2 or missing) are re-scored from their saved pitch files when shown, so old and new scores compare directly; files that cannot be re-scored (such as imported replays) put their saved raw total on the new curve.

## 6. Calibration results

Validated against notes.json and ref_f0.json produced by the engine from real songs (30-second CC-BY clips);
the fixtures are in [`app/test/scoring/fixtures/`](../app/test/scoring/fixtures/):

| Take | Total score | Rank |
| --- | --- | --- |
| The original singer's own F0 curve | 100.0 | SSS |
| Original singer transposed down 9 semitones (equivalent to up 3 semitones and down an octave), delayed by 300 ms | 100.0 | SSS (k = 9) |
| Random pitches | 30.8 (raw 11.0) | D |

Scoring a 5-minute song (about 19,000 frames, 650 notes) takes about 150 ms.

## 7. Known limitations

* Without a reference F0 curve, the expected onsets come from GAME's note boundaries and the target is the note's fixed pitch,
  so F0 tracking latency and natural pitch fluctuations cost a few points.
* When a note is entered early right after another note, that time belongs to the previous note's span, so the early amount may be underestimated; rushing after a rest is measured.
* Without a measured latency, a take that is early or late as a whole is treated as latency: it costs no rhythm points and no rushing / dragging verdict is given.
* Vibrato is scored only for songs in which the original singer uses a lot of vibrato; other songs rely on the other five sub-scores.
* Lyrics are not scored (speech recognition on Chinese and Japanese lyrics with accompaniment bleed is too error-prone for the resulting score to be meaningful).

## 8. References

Metric definitions follow the `melody` and `transcription` modules of mir_eval (Raffel et al., ISMIR 2014);
the 50 cent tolerance and octave equivalence for RPA / RCA come from Poliner et al. 2007 and Salamon et al. 2014;
the DTW band constraint comes from Sakoe & Chiba 1978. See [CITATIONS.md](CITATIONS.md) for full citations and BibTeX.

## 9. Development tools

```bash
cd app
flutter test test/scoring                                     # unit tests and real-data fixtures
dart run tool/score_files.dart notes.json take_f0.json ref_f0.json   # score arbitrary engine output
```
