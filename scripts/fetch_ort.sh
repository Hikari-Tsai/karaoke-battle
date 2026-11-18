#!/usr/bin/env bash
# Fetch the ONNX Runtime package the engine is compiled against (headers) and
# the runtime library that the app bundles.
#
#   macOS  -> engine/third_party/onnxruntime/osx-universal2/{include,lib}
#             (ORT 1.23.2; arm64 + x86_64 slices joined with lipo)
#   Linux  -> engine/third_party/onnxruntime/linux-x64/{include,lib} (dev only)
#
# Source: the Microsoft.ML.OnnxRuntime NuGet package. Until 2026-11 this came
# from the GitHub release (onnxruntime-osx-universal2-1.23.2.tgz), which went
# away with the microsoft/onnxruntime repository (issue #7). The NuGet dylibs
# are the same build: same size, Microsoft signature, CoreML EP included;
# only the signature timestamps differ.
#
# Windows uses scripts/fetch_ort.ps1.  Idempotent: when the directory already
# holds the right headers and a library with the expected sha256 nothing is
# downloaded.  Pass --force to re-download.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORT_VERSION="1.23.2"
NUPKG_URL="https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/${ORT_VERSION}/microsoft.ml.onnxruntime.${ORT_VERSION}.nupkg"
# sha256 of the package, recorded 2026-11-18 after a verified download.
NUPKG_SHA256="25fe172f7fcdf34f2b5b02c8b997f6b88abc282956849d4af4335af23d0c4e4a"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

case "$(uname -s)" in
  Darwin)
    PLATFORM="osx-universal2"
    LIB_REL="lib/libonnxruntime.${ORT_VERSION}.dylib"
    LIB_LINK="lib/libonnxruntime.dylib"
    # "<arch> <member in the nupkg> <accepted slice sha256s>". The second
    # hash of each arch is the slice of the old GitHub universal2 tgz, so a
    # copy fetched before the switch stays valid.
    SLICES=(
      "arm64 runtimes/osx-arm64/native/libonnxruntime.dylib d306d2bc768540766c7ed8a1e0ff05d2870c77a934ebeee4a7bafa1b732ef299 0708038eff766aed5559989aa0710d45546c469dc1bf85c6e83d603a98c10ae9"
      "x86_64 runtimes/osx-x64/native/libonnxruntime.dylib 8c9c78de65ea3786f987c0d980e9c1b13a3a5fbc6b3e2965ba05b450e6e4c054 a08cb244180fb71bd48dff0246b935ce43c8a894778a964f4aeac6ca16240c7b"
    )
    ;;
  Linux)
    PLATFORM="linux-x64"
    LIB_REL="lib/libonnxruntime.so.${ORT_VERSION}"
    LIB_LINK="lib/libonnxruntime.so"
    SLICES=(
      "x86_64 runtimes/linux-x64/native/libonnxruntime.so 13ab8084954fa4a47c777880180b90810d6020f021441395712b48a75b74c68b"
    )
    ;;
  *) echo "fetch_ort.sh: unsupported OS $(uname -s); use fetch_ort.ps1 on Windows" >&2; exit 1 ;;
esac

DEST="${ROOT}/engine/third_party/onnxruntime/${PLATFORM}"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

# The sha256 of the <arch> slice of $1 (the file itself on Linux).
slice_sha() {
  if [[ "${PLATFORM}" == "osx-universal2" ]]; then
    local t
    t="$(mktemp "${TMPDIR:-/tmp}/ort_slice.XXXXXX")"
    lipo "$1" -thin "$2" -output "${t}" 2>/dev/null || { rm -f "${t}"; echo none; return; }
    sha256_of "${t}"
    rm -f "${t}"
  else
    sha256_of "$1"
  fi
}

check_lib() {
  local lib="$1" entry arch member ok want got
  for entry in "${SLICES[@]}"; do
    read -r arch member want <<< "${entry}"
    got="$(slice_sha "${lib}" "${arch}")"
    ok=0
    for want in ${entry#* * }; do [[ "${got}" == "${want}" ]] && ok=1; done
    [[ ${ok} -eq 1 ]] || return 1
  done
  return 0
}

check_present() {
  [[ -f "${DEST}/include/onnxruntime_c_api.h" ]] || return 1
  [[ -f "${DEST}/${LIB_REL}" ]] || return 1
  check_lib "${DEST}/${LIB_REL}" || return 1
  if [[ -f "${DEST}/VERSION_NUMBER" ]]; then
    [[ "$(tr -d '[:space:]' < "${DEST}/VERSION_NUMBER")" == "${ORT_VERSION}" ]] || return 1
  fi
  return 0
}

if [[ ${FORCE} -eq 0 ]] && check_present; then
  echo "fetch_ort.sh: ONNX Runtime ${ORT_VERSION} (${PLATFORM}) already present at ${DEST} - nothing to do"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fetch_ort.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
PKG="${TMP}/ort.nupkg"

echo "fetch_ort.sh: downloading ${NUPKG_URL}"
curl -fsSL --retry 3 -o "${PKG}" "${NUPKG_URL}"
ACTUAL="$(sha256_of "${PKG}")"
if [[ "${ACTUAL}" != "${NUPKG_SHA256}" ]]; then
  echo "fetch_ort.sh: sha256 mismatch for $(basename "${NUPKG_URL}")" >&2
  echo "  expected ${NUPKG_SHA256}" >&2
  echo "  actual   ${ACTUAL}" >&2
  exit 1
fi
echo "fetch_ort.sh: sha256 OK"

mkdir -p "${TMP}/x"
MEMBERS=()
for entry in "${SLICES[@]}"; do
  read -r _ member _ <<< "${entry}"
  MEMBERS+=("${member}")
done
unzip -q "${PKG}" "${MEMBERS[@]}" 'build/native/include/*' LICENSE ThirdPartyNotices.txt -d "${TMP}/x"

# Stage the layout of the old release archive: include/, lib/, LICENSE...
STAGE="${DEST}.tmp.$$"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/include" "${STAGE}/lib"
# The package was built on Windows: drop the CRLFs so the headers match the
# release archive byte for byte.
for h in "${TMP}/x/build/native/include/"*; do
  tr -d '\r' < "${h}" > "${STAGE}/include/$(basename "${h}")"
done
[[ -f "${STAGE}/include/onnxruntime_c_api.h" ]] || { echo "fetch_ort.sh: package layout unexpected (no onnxruntime_c_api.h)" >&2; exit 1; }
cp "${TMP}/x/LICENSE" "${TMP}/x/ThirdPartyNotices.txt" "${STAGE}/"
echo "${ORT_VERSION}" > "${STAGE}/VERSION_NUMBER"
if [[ "${PLATFORM}" == "osx-universal2" ]]; then
  lipo -create "${MEMBERS[@]/#/${TMP}/x/}" -output "${STAGE}/${LIB_REL}"
  chmod 755 "${STAGE}/${LIB_REL}"
else
  cp "${TMP}/x/${MEMBERS[0]}" "${STAGE}/${LIB_REL}"
  chmod 755 "${STAGE}/${LIB_REL}"
fi
ln -s "$(basename "${LIB_REL}")" "${STAGE}/${LIB_LINK}"
check_lib "${STAGE}/${LIB_REL}" || { echo "fetch_ort.sh: library sha256 mismatch after assembly" >&2; exit 1; }

# Replace atomically: swap the staged directory in.
mkdir -p "$(dirname "${DEST}")"
rm -rf "${DEST}"
mv "${STAGE}" "${DEST}"

if [[ "${PLATFORM}" == "osx-universal2" ]]; then
  lipo -info "${DEST}/${LIB_REL}"
fi
echo "fetch_ort.sh: installed ONNX Runtime ${ORT_VERSION} to ${DEST}"
ls "${DEST}"
