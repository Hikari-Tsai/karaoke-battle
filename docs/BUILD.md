# Building Karaoke Battle

Two parts: the C++ engine (`engine/`, CMake) and the Flutter desktop app (`app/`).
ONNX Runtime is **never linked** - the engine needs its headers at build time and the
app hands the engine the path of the runtime library at run time
(`ke_runtime_create(path, ep, ...)`). The `scripts/` directory holds everything that
fetches third-party binaries; nothing under `engine/third_party/onnxruntime/` is committed.

| | macOS | Windows |
| --- | --- | --- |
| ORT package | 1.23.2 `osx-universal2` (GitHub release tgz) | DirectML build 1.24.4 (NuGet `Microsoft.ML.OnnxRuntime.DirectML`) + `Microsoft.AI.DirectML` 1.15.4 |
| Fetch script | `scripts/fetch_ort.sh` | `scripts/fetch_ort.ps1` |
| Engine build | `scripts/build_engine.sh` (Ninja, arm64 + x86_64) | `scripts/build_engine.ps1` (VS 2022, x64) |
| Engine output | `engine/build/libkaraoke_engine.dylib`, `engine/build/ke_cli` | `engine/build/Release/karaoke_engine.dll`, `ke_cli.exe` |
| App output | `app/build/macos/Build/Products/Release/karaoke_battle.app` | `app/build/windows/x64/runner/Release/karaoke_battle.exe` |

All scripts verify the sha256 of what they download (expected values are embedded in the
scripts) and are idempotent - re-running them is a no-op when the files are present and correct.

## Prerequisites

### macOS (builds the universal app)

* macOS 13+ with Xcode 15+ (`xcode-select --install` is not enough: `flutter build macos`
  needs the full Xcode) and CocoaPods (`brew install cocoapods` or `sudo gem install cocoapods`).
* `brew install cmake ninja` (CMake >= 3.21).
* Flutter stable with macOS desktop enabled: `flutter config --enable-macos-desktop`.
* Optional for a distributable DMG: `brew install create-dmg`, a "Developer ID Application"
  certificate and an App Store Connect app-specific password for notarization.

### Windows (x64)

* Visual Studio 2022 with the **Desktop development with C++** workload (MSVC v143,
  Windows 10/11 SDK). The `build_engine.ps1` script uses the `Visual Studio 17 2022`
  generator with `-A x64`.
* CMake >= 3.21 on `PATH` (the VS installer's CMake or https://cmake.org).
* Flutter stable with Windows desktop enabled: `flutter config --enable-windows-desktop`.
* PowerShell 5.1 or 7 (`pwsh`). If scripts are blocked:
  `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.

## Local build - macOS

```bash
# 1. ONNX Runtime headers + universal2 dylib -> engine/third_party/onnxruntime/osx-universal2/{include,lib}
./scripts/fetch_ort.sh            # no-op if already present with the right sha256; --force to redo

# 2. Engine (Release, arm64 + x86_64) + `lipo` check + `ke_cli gpu` smoke test
./scripts/build_engine.sh         # --clean wipes engine/build first; --debug; --no-smoke

# 3. Flutter app
cd app
flutter pub get
flutter build macos --release
APP=build/macos/Build/Products/Release/karaoke_battle.app

# 4. Put the engine and the runtime into the bundle (CI does exactly this)
mkdir -p "$APP/Contents/Frameworks"
cp ../engine/build/libkaraoke_engine.dylib "$APP/Contents/Frameworks/"
cp ../engine/third_party/onnxruntime/osx-universal2/lib/libonnxruntime.1.23.2.dylib "$APP/Contents/Frameworks/"

# 5. Re-sign (the bundle changed). Ad-hoc is enough to run locally:
codesign --force --deep --sign - "$APP"
open "$APP"
```

Checks worth running after step 2:

```bash
lipo -info engine/build/libkaraoke_engine.dylib      # -> x86_64 arm64
engine/build/ke_cli gpu                               # JSON list of GPUs
engine/build/ke_cli runtime --ort engine/third_party/onnxruntime/osx-universal2/lib/libonnxruntime.1.23.2.dylib --ep cpu
engine/build/ke_cli runtime --ort engine/third_party/onnxruntime/osx-universal2/lib/libonnxruntime.1.23.2.dylib --ep coreml
```

Developer-ID signing for distribution (what CI does when the secrets exist): sign every
dylib in `Contents/Frameworks` with `--options runtime --timestamp`, then the `.app` with
`app/macos/Runner/Release.entitlements`, build the DMG, sign the DMG, `xcrun notarytool
submit --wait`, `xcrun stapler staple`. Because the engine and ORT dylibs are signed with the
same Team ID as the app, hardened-runtime library validation passes without the
`disable-library-validation` entitlement. The app spawns yt-dlp/ffmpeg/deno from the
app-support directory; with the App Sandbox on, those child processes inherit the sandbox,
so the sidecar directory must be inside the app container and the
`com.apple.security.network.client` and `com.apple.security.device.audio-input`
entitlements are required.

## Local build - Windows

```powershell
# 1. ORT DirectML headers + DLLs -> engine\third_party\onnxruntime\win-x64\{include,lib}
.\scripts\fetch_ort.ps1           # -Force to redo

# 2. Engine (VS 2022 x64, Release) + `ke_cli gpu`
.\scripts\build_engine.ps1        # -Clean, -Debug, -NoSmoke

# 3. Flutter app
cd app
flutter pub get
flutter build windows --release
$out = "build\windows\x64\runner\Release"

# 4. DLLs next to the exe (CI does exactly this)
Copy-Item ..\engine\build\Release\karaoke_engine.dll $out
Copy-Item ..\engine\third_party\onnxruntime\win-x64\lib\onnxruntime.dll $out
Copy-Item ..\engine\third_party\onnxruntime\win-x64\lib\onnxruntime_providers_shared.dll $out
Copy-Item ..\engine\third_party\onnxruntime\win-x64\lib\DirectML.dll $out
& "$out\karaoke_battle.exe"
```

Checks:

```powershell
engine\build\Release\ke_cli.exe gpu
engine\build\Release\ke_cli.exe runtime --ort engine\third_party\onnxruntime\win-x64\lib\onnxruntime.dll --ep directml
```

The Flutter Windows runner already requires the Visual C++ 2022 x64 redistributable
(`MSVCP140.dll`, `VCRUNTIME140*.dll`); `onnxruntime.dll` and the CUDA pack need the same
redistributable (the CUDA EP additionally needs `MSVCP140_ATOMIC_WAIT.dll`, part of the
same package). Ship the redistributable in the installer or `vc_redist.x64.exe` from the
first-run flow.

## How the ORT library is located at run time

The Dart side resolves these paths and passes the ORT one to `ke_runtime_create`.
Nothing relies on `PATH`, `DYLD_LIBRARY_PATH` or the working directory.

### macOS

```
karaoke_battle.app/
  Contents/
    MacOS/karaoke_battle                        Flutter runner (rpath @executable_path/../Frameworks)
    Frameworks/
      libkaraoke_engine.dylib                   engine (install name @rpath/libkaraoke_engine.dylib)
      libonnxruntime.1.23.2.dylib               ORT 1.23.2 universal2 (CPU + CoreML EPs built in)
      FlutterMacOS.framework, App.framework, ...
```

* Engine: `DynamicLibrary.open('<bundle>/Contents/Frameworks/libkaraoke_engine.dylib')`.
  Use the absolute path (`dlopen` of a bare leaf name does not search `@rpath`). The bundle
  path is `File(Platform.resolvedExecutable).parent.parent.parent.path`.
* ORT: `<bundle>/Contents/Frameworks/libonnxruntime.1.23.2.dylib` ->
  `ke_runtime_create(path, KE_EP_COREML or KE_EP_CPU, 0, 0, &rt)`. The engine `dlopen`s it with
  `RTLD_NOW | RTLD_LOCAL` by absolute path; the dylib's install name does not matter.
* There is no optional pack on macOS.

### Windows

```
<install dir>\
  karaoke_battle.exe                          Flutter runner
  flutter_windows.dll, data\, ...
  karaoke_engine.dll                          engine
  onnxruntime.dll                             ORT 1.24.4 DirectML build (CPU + DirectML EPs)
  onnxruntime_providers_shared.dll            shipped with the package (harmless, keep it)
  DirectML.dll                                DirectML 1.15.4 (loaded by onnxruntime.dll)
```

* Engine: `DynamicLibrary.open('<exe dir>\karaoke_engine.dll')` where
  `<exe dir> = File(Platform.resolvedExecutable).parent.path`.
* Base ORT: `<exe dir>\onnxruntime.dll` -> `ke_runtime_create(path, KE_EP_DIRECTML or KE_EP_CPU, adapter, 0, &rt)`.
  The engine loads it with `LoadLibraryExW(..., LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR)`,
  so `DirectML.dll` is resolved from the same directory as `onnxruntime.dll`.
* CUDA pack (optional, downloaded by the app, see `scripts/cuda_pack.json` and `docs/BACKENDS.md`):

  ```
  <app support>\cuda_pack\
    onnxruntime.dll                           ORT 1.31.1 win-x64-gpu_cuda12 (CPU + CUDA EPs)
    onnxruntime_providers_shared.dll
    onnxruntime_providers_cuda.dll
    cudart64_12.dll  cublas64_12.dll  cublasLt64_12.dll  cufft64_11.dll
    cudnn64_9.dll  cudnn_graph64_9.dll  cudnn_ops64_9.dll  cudnn_cnn64_9.dll  cudnn_adv64_9.dll
    cudnn_engines_precompiled64_9.dll  cudnn_engines_runtime_compiled64_9.dll
    cudnn_engines_tensor_ir64_9.dll  cudnn_ext64_9.dll  cudnn_heuristic64_9.dll
    manifest.json                             copy of scripts/cuda_pack.json + per-file sha256 written after install
  ```

  `<app support>` is `path_provider`'s `getApplicationSupportDirectory()`
  (`%APPDATA%\com.karaokebattle\karaoke_battle` or similar). The app passes
  `<app support>\cuda_pack\onnxruntime.dll` with `KE_EP_CUDA`; the same
  `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR` flag makes every CUDA DLL resolve from that directory,
  so the pack must be flat (no sub-directories) and `nvcuda.dll` comes from the driver.
  Only one `onnxruntime.dll` may be loaded per process: pick the backend once at start-up
  (or restart the engine process after switching).

All three runtimes serve `ORT_API_VERSION 23` (the headers the engine is compiled against);
`ke_runtime_create` fails with `KE_ERR_ORT_LOAD` if a library does not.

## Sidecars and models

Not part of the build. `scripts/sidecars.json` pins yt-dlp 2026.10.26 (`yt-dlp_macos` is a
universal2 binary; `yt-dlp.exe` needs Windows 10+), Deno 2.9.8 (required by yt-dlp for
YouTube; per-architecture zips) and ffmpeg/ffprobe 9.0.2 (martin-riedl.de per-arch static
builds on macOS - GPLv3; BtbN `win64-lgpl` on Windows - LGPLv3), each with URL, size and
sha256. Models come from Hugging Face `aaatmy/*` (see `docs/ARCHITECTURE.md`). The app
downloads all of these into `<app support>/sidecars/` and `<app support>/models/` on first run.

## CI (`.github/workflows/build.yml`)

* Triggers: push to `main`, pull requests, `workflow_dispatch`, tags `v*`. One run per ref
  (`concurrency` with `cancel-in-progress`).
* `macos` (macos-14): fetch ORT -> `build_engine.sh --clean` -> `lipo -verify_arch arm64 x86_64`
  on the engine, `ke_cli` and ORT -> `flutter build macos --release` -> copy the two dylibs into
  `Contents/Frameworks` -> sign (Developer ID when `MACOS_CERT_P12`/`MACOS_CERT_PASSWORD`
  exist, else ad-hoc) -> DMG (`create-dmg`, `hdiutil` fallback) -> notarize + staple when
  `APPLE_ID`/`APPLE_TEAM_ID`/`APPLE_APP_PASSWORD` also exist -> artifact
  `KaraokeBattle-macos-universal` (`KaraokeBattle-<version>-macos-universal.dmg`).
* `windows` (windows-latest): `fetch_ort.ps1` -> `build_engine.ps1 -Clean` ->
  `flutter build windows --release` -> copy `karaoke_engine.dll`, `onnxruntime.dll`,
  `onnxruntime_providers_shared.dll`, `DirectML.dll` next to the exe -> artifact
  `KaraokeBattle-windows-x64` (`KaraokeBattle-<version>-windows-x64.zip`).
* Both jobs also upload the bare engine (`engine-macos-universal`, `engine-windows-x64`)
  and skip the Flutter steps with a warning while `app/pubspec.yaml` does not exist.
* `release` (tags only): downloads both artifacts, writes `SHA256SUMS-<version>.txt` and
  creates the GitHub Release with `softprops/action-gh-release`. A tag containing `-`
  (e.g. `v1.2.0-beta.1`) is marked as a pre-release.
* The version comes from the tag (`v1.2.3` -> `--build-name 1.2.3`), `--build-number` is the
  run number; non-tag builds use `0.0.0`.
* Every action is pinned to a commit SHA (version in the trailing comment).
