# Inference backends

The engine runs every model (MDX-Net separation, GAME transcription, SwiftF0) through ONNX
Runtime with one execution provider (EP) chosen at start-up. Preference order:
**CUDA -> DirectML -> CPU** on Windows, **CoreML (fixed-shape models) / CPU** on macOS.

> Fallbacks never change the result. Every backend runs the same ONNX graphs with the same
> parameters; only speed differs (float rounding differences are far below what the scoring
> metrics can resolve). The GAME segmenter is stochastic by design on every backend.

## Packages

| Backend | Library | Where it comes from |
| --- | --- | --- |
| macOS CPU / CoreML | `libonnxruntime.1.23.2.dylib` (universal2) | bundled in `<App>.app/Contents/Frameworks` |
| Windows DirectML / CPU | `onnxruntime.dll` 1.24.4 + `DirectML.dll` 1.15.4 | bundled next to the exe |
| Windows CUDA | `onnxruntime.dll` 1.31.1 (`win-x64-gpu_cuda12`) + `onnxruntime_providers_cuda.dll` + CUDA 12.9 / cuDNN 9.27 DLLs | downloaded on demand into `<app support>/cuda_pack/` - `scripts/cuda_pack.json` (1.89 GB download, 2.59 GB on disk) |

Requirements for the CUDA pack: NVIDIA GPU, **driver >= 527.41** (CUDA 12 baseline on
Windows), ~2.6 GB free disk, VC++ 2022 redistributable. Compute capability 7.5+ (GTX 16xx /
RTX 20xx or newer) is recommended; older cards fall back to PTX JIT on first run (slow start).

## Drawbacks per backend

**CPU** (macOS fallback, Windows last resort)

* MDX-Net separation of a 4-minute song takes minutes instead of seconds (two models,
  overlapping 256-frame chunks); GAME transcription is a multi-step diffusion loop that is
  also several times slower.
* Saturates all cores during prep; the UI stays responsive (work runs in the engine's
  threads) but the machine does not.
* Live SwiftF0 at 160 ms cadence is fine on CPU; only the prep pipeline suffers.

**CoreML** (macOS, Apple silicon)

* Used only for fixed-shape graphs (SwiftF0 windows, MDX chunks); dynamic-shape GAME graphs
  stay on CPU. Unsupported ops are partitioned back to CPU automatically. Gains are modest; it
  is an optimisation, not a separate "mode", so there is no dialog on macOS.

**DirectML** (Windows, any DX12 GPU: NVIDIA, AMD, Intel, Qualcomm)

* Graphs are compiled per input shape: every new chunk length / window size triggers a
  recompilation (first song, first live window, each distinct slice length in GAME). Expect
  stalls of a few seconds the first time each shape is seen.
* `STFT`, `Einsum` and the random-number ops (`RandomUniformLike` in the GAME segmenter) are
  not implemented by the DirectML EP and fall back to CPU with GPU<->CPU copies around them.
* Typically 2-4x slower than the CUDA EP on the same NVIDIA GPU; still far faster than CPU.
* Shares VRAM with the streaming software - on 4 GB cards MDX-Net may fail to allocate; the
  engine retries on CPU per job.

**CUDA** (Windows, NVIDIA only)

* Fastest. Costs a 1.9 GB download and ~2.6 GB disk. Needs a recent driver. The pack carries
  its own `onnxruntime.dll` (1.31.1), so it replaces the DirectML build for that session.

## Decision tree (run at start-up and when the user changes the backend setting)

```
start
 |- macOS ---------------------------------------------------> CPU (+CoreML for fixed-shape models). No dialog.
 |- Windows
     |- ke_system_gpu_info_json(): any adapter with vendor == "nvidia"?
     |   |- no ---------------------------------------------> DirectML (adapter 0 / user choice). Dialog W1 once.
     |   |- yes
     |       |- driver version < 527.41? --------------------> DirectML now. Dialog W2 (update driver).
     |       |- cuda_pack present and manifest sha256 OK?
     |       |   |- no -------------------------------------> DirectML now. Dialog W3 (offer download, size).
     |       |   |- yes
     |       |       |- ke_runtime_create(cuda_pack/onnxruntime.dll, KE_EP_CUDA) + ke_runtime_selftest OK?
     |       |           |- yes ---------------------------> CUDA. No dialog.
     |       |           |- no ----------------------------> DirectML. Dialog W4 (self-test failed, offer re-download).
     |- user setting "force CPU" / all GPU EPs failed --------> CPU. Dialog W5 (CPU warning) once.
```

Notes for `services/backend.dart`:

* "Driver version" = the NVIDIA driver (e.g. `546.33`), read from the DXGI adapter's
  `DriverVersion` / registry or by running `nvidia-smi --query-gpu=driver_version --format=csv,noheader`
  when present. Compare as `major.minor` numerically.
* Pack validity = `manifest.json` present, every listed file present with matching size and
  sha256 (hash check can be cached by mtime after the first full verification).
* The self-test loads SwiftF0 and runs one window; it takes well under a second on a warm
  GPU but may take 10-30 s the first time on an older GPU (PTX JIT) - show a spinner.
* After W4 the pack is marked `broken` so the self-test is not repeated on every launch;
  re-download clears the mark. The user can also pick a backend manually in Settings.
* Remember "don't ask again" per dialog (W1, W3, W5). W2 re-appears whenever the driver is
  still too old and no pack is installed.

## Dialog texts

Primary language is Traditional Chinese (zh-TW); English second. `{size}` is
`download_total_human` from `scripts/cuda_pack.json` (currently `1.89 GB`), `{disk}` the
installed size (`2.59 GB`), `{driver}` the detected driver version, `{gpu}` the adapter name.

### W1 - Windows, no NVIDIA GPU (DirectML selected)

**zh-TW**
標題：使用 DirectML 加速
內容：偵測到 {gpu}。將使用 DirectML（DirectX 12）執行 AI 模型。
DirectML 的限制：
• 每遇到新的輸入長度就需要重新編譯模型，第一次處理每首歌或每個段落時會停頓數秒。
• STFT、Einsum 與隨機數運算不支援 GPU，會自動改在 CPU 執行，速度較慢。
• 整體速度低於 NVIDIA CUDA。
評分結果不受影響，只有處理速度不同。
按鈕：[知道了] [設定…]　☐ 不再顯示

**English**
Title: Using DirectML acceleration
Body: Detected {gpu}. AI models will run through DirectML (DirectX 12).
DirectML limitations:
• Models are recompiled for every new input shape, so the first time each song or segment is processed there is a pause of a few seconds.
• STFT, Einsum and random-number operators are not supported on the GPU and run on the CPU instead.
• Slower overall than NVIDIA CUDA.
Scoring accuracy is unaffected; only processing speed differs.
Buttons: [OK] [Settings...]  ☐ Don't show again

### W2 - NVIDIA GPU with driver < 527.41

**zh-TW**
標題：請更新 NVIDIA 驅動程式
內容：偵測到 {gpu}，但驅動程式版本 {driver} 太舊。CUDA 加速需要 527.41 或更新的驅動程式。
更新前將暫時使用 DirectML（速度較慢，評分結果相同）。
請到 NVIDIA 官方網站或 GeForce Experience / NVIDIA App 下載最新驅動程式，安裝後重新啟動本程式。
按鈕：[前往 NVIDIA 下載頁面] [先用 DirectML]

**English**
Title: Please update your NVIDIA driver
Body: Detected {gpu}, but driver version {driver} is too old. CUDA acceleration requires driver 527.41 or newer.
Until then DirectML will be used (slower, same scoring results).
Download the latest driver from nvidia.com or GeForce Experience / NVIDIA App, install it and restart this application.
Buttons: [Open NVIDIA download page] [Use DirectML for now]

(Link: https://www.nvidia.com/Download/index.aspx)

### W3 - NVIDIA GPU OK, CUDA pack not installed

**zh-TW**
標題：下載 CUDA 加速套件？
內容：偵測到 {gpu}（驅動程式 {driver}）。安裝 CUDA 加速套件後，人聲分離與音符辨識可比 DirectML 快數倍。
下載大小：{size}，安裝後約佔 {disk} 磁碟空間。可在背景下載，完成後自動啟用。
在此之前將使用 DirectML（評分結果相同）。
按鈕：[下載並安裝] [稍後再說]　☐ 不再詢問（可在設定中重新啟用）

**English**
Title: Download the CUDA acceleration pack?
Body: Detected {gpu} (driver {driver}). With the CUDA pack installed, vocal separation and note transcription run several times faster than with DirectML.
Download size: {size}; about {disk} of disk space after installation. It downloads in the background and is enabled automatically when finished.
DirectML will be used until then (same scoring results).
Buttons: [Download and install] [Not now]  ☐ Don't ask again (can be re-enabled in Settings)

Progress toast while downloading: 「正在下載 CUDA 加速套件… {percent}%（{done}/{size}）」 /
"Downloading CUDA pack... {percent}% ({done}/{size})". On completion: 「CUDA 加速已啟用」 /
"CUDA acceleration enabled" (and the self-test result).

### W4 - CUDA pack present but self-test failed

**zh-TW**
標題：CUDA 加速套件無法使用
內容：已安裝 CUDA 加速套件，但啟動自我測試失敗：
{error}
已自動改用 DirectML，評分結果不受影響。常見原因：檔案損毀、驅動程式剛更新、或 VRAM 不足。
按鈕：[重新下載套件] [繼續使用 DirectML] [查看記錄]

**English**
Title: CUDA pack is not working
Body: The CUDA acceleration pack is installed but its start-up self-test failed:
{error}
DirectML is being used instead; scoring results are unaffected. Common causes: corrupted files, a driver that was just updated, or insufficient VRAM.
Buttons: [Re-download pack] [Keep using DirectML] [Show log]

`{error}` is `ke_last_error()` (e.g. `KE_ERR_EP_UNAVAILABLE: CUDA_PATH ... cudnn64_9.dll not found`).
"Re-download" deletes `<app support>/cuda_pack/`, then runs the W3 download flow.

### W5 - CPU only (no usable GPU backend, or forced in Settings)

**zh-TW**
標題：僅使用 CPU 運算
內容：找不到可用的 GPU 加速（或已在設定中停用）。AI 模型將完全在 CPU 上執行：
• 人聲分離與音符辨識會明顯變慢（一首歌可能需要數分鐘）。
• 處理期間 CPU 使用率會很高。
• 即時音高偵測與評分不受影響。
按鈕：[知道了] [設定…]　☐ 不再顯示

**English**
Title: Running on CPU only
Body: No usable GPU acceleration was found (or it is disabled in Settings). AI models will run entirely on the CPU:
• Vocal separation and note transcription are much slower (a song can take several minutes).
• CPU usage is high while a song is being prepared.
• Live pitch tracking and scoring are unaffected.
Buttons: [OK] [Settings...]  ☐ Don't show again

### macOS

No dialog. The Settings page shows the active backend as 「CPU（CoreML 輔助）」 /
"CPU (CoreML assisted)" for information only.

## Settings page summary line

「目前後端：{backend}　{gpu}」 / "Current backend: {backend} {gpu}" with `{backend}` one of
`CUDA`, `DirectML`, `CPU`, `CPU + CoreML`, plus a [變更…]/[Change...] button that offers the
list from the decision tree (CUDA only when the pack is installed and the self-test passed)
and the 「下載 CUDA 加速套件」/"Download CUDA pack" / 「移除 CUDA 加速套件（釋放 {disk}）」/
"Remove CUDA pack (frees {disk})" actions.
