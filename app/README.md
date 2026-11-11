# Karaoke Battle: Flutter app

The desktop app (macOS / Windows) of [Karaoke Battle](../README.md), a karaoke scoring app for
streamers by Hikari Tsai, MIT License. The audio engine it loads lives in [`../engine`](../engine).

The package name `karaoke_battle` is only Flutter's internal identifier; the app is shown as
"Karaoke Battle".

## Run from source

Build the engine and fetch ONNX Runtime first (see [docs/BUILD.md](../docs/BUILD.md)), then:

```bash
flutter run -d macos      # or: -d windows
flutter test
```

- Install steps for users: [docs/INSTALL.md](../docs/INSTALL.md)
- How the app and the engine fit together: [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)
