<#
.SYNOPSIS
  Configure + build the C++ engine with the newest Visual Studio x64 generator and run `ke_cli gpu`.

.DESCRIPTION
    scripts\build_engine.ps1 [-Clean] [-DebugBuild] [-NoSmoke]

  Output: engine\build\Release\{karaoke_engine.dll, karaoke_engine.lib, ke_cli.exe}
  (engine\build\Debug\... with -DebugBuild). Override the build directory with $env:KE_BUILD_DIR.
  Requires CMake >= 3.21 and Visual Studio 2022 or newer with the "Desktop development with C++" workload
  (both preinstalled on GitHub's windows-latest runners).

  Not executed on the macOS development machine; exercised by the windows job of
  .github/workflows/build.yml.
#>
[CmdletBinding()]
param(
  [switch]$Clean,
  [switch]$DebugBuild,
  [switch]$NoSmoke
)
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Engine = Join-Path $Root 'engine'
$BuildDir = if ($env:KE_BUILD_DIR) { $env:KE_BUILD_DIR } else { Join-Path $Engine 'build' }
$Config = if ($DebugBuild) { 'Debug' } else { 'Release' }

if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { throw 'cmake not found on PATH' }

# Headers are needed at configure time.
& (Join-Path $PSScriptRoot 'fetch_ort.ps1')
if ($LASTEXITCODE -ne 0) { throw "fetch_ort.ps1 failed ($LASTEXITCODE)" }

if ($Clean -and (Test-Path $BuildDir)) { Remove-Item -Recurse -Force $BuildDir }

# Use the newest Visual Studio generator CMake can find (2022 on windows-2022 runners,
# 2026 on windows-latest); override with $env:KE_CMAKE_GENERATOR if needed.
if ($env:KE_CMAKE_GENERATOR) {
  & cmake -S $Engine -B $BuildDir -G $env:KE_CMAKE_GENERATOR -A x64
} else {
  & cmake -S $Engine -B $BuildDir -A x64
}
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }
& cmake --build $BuildDir --config $Config --parallel
if ($LASTEXITCODE -ne 0) { throw "cmake build failed ($LASTEXITCODE)" }

$OutDir = Join-Path $BuildDir $Config
$Dll = Join-Path $OutDir 'karaoke_engine.dll'
$Cli = Join-Path $OutDir 'ke_cli.exe'
if (-not (Test-Path $Dll)) { throw "expected output missing: $Dll" }
if (-not (Test-Path $Cli)) { throw "expected output missing: $Cli" }
Get-Item $Dll, $Cli | ForEach-Object { Write-Host ("  {0,12}  {1}" -f $_.Length, $_.FullName) }

if (-not $NoSmoke) {
  Write-Host 'build_engine.ps1: smoke test - ke_cli gpu'
  # ke_cli.exe sits next to karaoke_engine.dll, so the DLL is found via the application directory.
  & $Cli gpu
  if ($LASTEXITCODE -ne 0) { throw "ke_cli gpu failed ($LASTEXITCODE)" }
}
Write-Host 'build_engine.ps1: done'
