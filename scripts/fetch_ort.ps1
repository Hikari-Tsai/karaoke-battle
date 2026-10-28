<#
.SYNOPSIS
  Fetch the ONNX Runtime DirectML package (headers + runtime DLLs) for Windows x64.

.DESCRIPTION
  Downloads the Microsoft.ML.OnnxRuntime.DirectML 1.24.4 and Microsoft.AI.DirectML 1.15.4
  NuGet packages (plain zip files), verifies their sha256, and lays them out as

    engine/third_party/onnxruntime/win-x64/
      include/            onnxruntime_c_api.h, dml_provider_factory.h, ...
      lib/                onnxruntime.dll, onnxruntime.lib, onnxruntime_providers_shared.dll, DirectML.dll
      LICENSE-onnxruntime.txt, LICENSE-DirectML.txt

  The engine never links onnxruntime; it only needs the headers at build time. The DLLs are
  copied next to the Flutter executable by the CI workflow / BUILD.md instructions.

  Idempotent: exits early when the headers and both DLLs are present with the expected hashes.
  -Force re-downloads. Works on Windows PowerShell 5.1 and PowerShell 7.

  Not executed on the macOS development machine; exercised by the windows job of
  .github/workflows/build.yml.
#>
[CmdletBinding()]
param(
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$OrtVersion = '1.24.4'
$DmlVersion = '1.15.4'

# sha256 values recorded 2026-10-28 after a verified download.
$OrtPkg = @{
  Url    = "https://www.nuget.org/api/v2/package/Microsoft.ML.OnnxRuntime.DirectML/$OrtVersion"
  File   = "microsoft.ml.onnxruntime.directml.$OrtVersion.nupkg"
  Sha256 = '57e9f11b73437bef7a309496135d4c1f96b1a8e9ddba60013fa27bfc1d788681'
}
$DmlPkg = @{
  Url    = "https://www.nuget.org/api/v2/package/Microsoft.AI.DirectML/$DmlVersion"
  File   = "microsoft.ai.directml.$DmlVersion.nupkg"
  Sha256 = '4e7cb7ddce8cf837a7a75dc029209b520ca0101470fcdf275c1f49736a3615b9'
}
$ExpectedDll = @{
  'onnxruntime.dll'                  = 'e7eedec6a6f26dc39dc948276a75ef6d2bee3fff944d874ceed0bbd3b97bff40'
  'onnxruntime_providers_shared.dll' = '265c8daf29637cb259cac8be9f08f2cd45f3883f0f0e4949cbfddd5b4cbec3b6'
  'DirectML.dll'                     = '9c9e6d822561c6c41b90e6994b3e8857cf1d66dbfb1e0c4c799c7c89b4e92da1'
}

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Dest = Join-Path $Root 'engine\third_party\onnxruntime\win-x64'

function Get-Sha256([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

function Test-Present {
  if (-not (Test-Path (Join-Path $Dest 'include\onnxruntime_c_api.h'))) { return $false }
  foreach ($name in $ExpectedDll.Keys) {
    $p = Join-Path $Dest "lib\$name"
    if (-not (Test-Path $p)) { return $false }
    if ((Get-Sha256 $p) -ne $ExpectedDll[$name]) { return $false }
  }
  return $true
}

if (-not $Force -and (Test-Present)) {
  Write-Host "fetch_ort.ps1: ONNX Runtime DirectML $OrtVersion + DirectML $DmlVersion already present at $Dest - nothing to do"
  exit 0
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("fetch_ort_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
  foreach ($pkg in @($OrtPkg, $DmlPkg)) {
    $out = Join-Path $Tmp $pkg.File
    Write-Host "fetch_ort.ps1: downloading $($pkg.Url)"
    Invoke-WebRequest -Uri $pkg.Url -OutFile $out -UseBasicParsing -MaximumRedirection 5
    $actual = Get-Sha256 $out
    if ($actual -ne $pkg.Sha256) {
      throw "sha256 mismatch for $($pkg.File): expected $($pkg.Sha256), got $actual"
    }
    Write-Host "fetch_ort.ps1: sha256 OK ($($pkg.File))"
    # Expand-Archive insists on a .zip extension.
    $zip = "$out.zip"
    Copy-Item $out $zip
    Expand-Archive -Path $zip -DestinationPath (Join-Path $Tmp ([IO.Path]::GetFileNameWithoutExtension($pkg.File))) -Force
  }

  $ortX = Join-Path $Tmp ([IO.Path]::GetFileNameWithoutExtension($OrtPkg.File))
  $dmlX = Join-Path $Tmp ([IO.Path]::GetFileNameWithoutExtension($DmlPkg.File))

  $stage = "$Dest.tmp"
  if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
  New-Item -ItemType Directory -Path (Join-Path $stage 'include') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $stage 'lib') | Out-Null

  Copy-Item (Join-Path $ortX 'build\native\include\*') (Join-Path $stage 'include') -Recurse
  foreach ($f in 'onnxruntime.dll', 'onnxruntime.lib', 'onnxruntime_providers_shared.dll') {
    Copy-Item (Join-Path $ortX "runtimes\win-x64\native\$f") (Join-Path $stage 'lib')
  }
  Copy-Item (Join-Path $dmlX 'bin\x64-win\DirectML.dll') (Join-Path $stage 'lib')
  if (Test-Path (Join-Path $ortX 'LICENSE.txt')) { Copy-Item (Join-Path $ortX 'LICENSE.txt') (Join-Path $stage 'LICENSE-onnxruntime.txt') }
  if (Test-Path (Join-Path $dmlX 'LICENSE.txt')) { Copy-Item (Join-Path $dmlX 'LICENSE.txt') (Join-Path $stage 'LICENSE-DirectML.txt') }
  Set-Content -Path (Join-Path $stage 'VERSION_NUMBER') -Value "$OrtVersion (DirectML $DmlVersion)"

  foreach ($name in $ExpectedDll.Keys) {
    $actual = Get-Sha256 (Join-Path $stage "lib\$name")
    if ($actual -ne $ExpectedDll[$name]) { throw "sha256 mismatch for extracted $name : expected $($ExpectedDll[$name]), got $actual" }
  }
  if (-not (Test-Path (Join-Path $stage 'include\onnxruntime_c_api.h'))) { throw 'package layout unexpected: include\onnxruntime_c_api.h missing' }

  if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
  New-Item -ItemType Directory -Path (Split-Path $Dest) -Force | Out-Null
  Move-Item $stage $Dest
  Write-Host "fetch_ort.ps1: installed ONNX Runtime DirectML $OrtVersion + DirectML $DmlVersion to $Dest"
  Get-ChildItem -Recurse $Dest | Where-Object { -not $_.PSIsContainer } | ForEach-Object { Write-Host ("  {0,12}  {1}" -f $_.Length, $_.FullName.Substring($Dest.Length + 1)) }
}
finally {
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
