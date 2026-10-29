# Cloud Seed core (vendored)

Source: https://github.com/GhostNoteAudio/CloudSeedCore, commit
`deb21ded9eb7dad9b3ff94ce1ba96a963716594e` (2024-09-22).
Copyright (c) 2024 Ghost Note Audio. MIT License, see `LICENSE`.
Karaoke Battle is not made by or affiliated with Ghost Note Audio.

Only the DSP (`DSP/`) and `Parameters.h` are used; the demo program, the
preset table and the parameter labels are left out. Changes for Karaoke Battle:

* Delay buffers sized for 48 kHz instead of 192 kHz (`ModulatedDelay`,
  `MultitapDelay`, `ModulatedAllpass`) and 8 late lines instead of 12, which
  brings one stereo instance from about 60 MB to about 12 MB. The engine's
  wrapper (`engine/src/dsp/hall_reverb.*`) never runs it above 48 kHz.
* The `BUFFER_SIZE` build define is now `CLOUDSEED_BUFFER_SIZE` with a
  default in `DSP/Utils.h`, plus an `M_PI` fallback for MSVC.
* `FormatParameter` (MSVC-only `strcpy_s`) and the `ParameterLabel` table
  were removed from `Parameters.h`.

The "vocal hall" program the app uses lives in `engine/src/dsp/hall_reverb.cpp`.
