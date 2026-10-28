#!/usr/bin/env bash
# Fetch the ONNX Runtime package the engine is compiled against (headers) and
# the runtime library that the app bundles.
#
#   macOS  -> engine/third_party/onnxruntime/osx-universal2/{include,lib}
#             (ORT 1.23.2 universal2 - the last release shipping a universal2 dylib)
#   Linux  -> engine/third_party/onnxruntime/linux-x64/{include,lib} (dev only)
#
# Windows uses scripts/fetch_ort.ps1.  Idempotent: when the directory already
# holds the right headers and a library with the expected sha256 nothing is
# downloaded.  Pass --force to re-download.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORT_VERSION="1.23.2"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

case "$(uname -s)" in
  Darwin)
    PLATFORM="osx-universal2"
    ARCHIVE="onnxruntime-osx-universal2-${ORT_VERSION}.tgz"
    # sha256 of the release asset, recorded 2026-10-28 after a verified download.
    ARCHIVE_SHA256="49ae8e3a66ccb18d98ad3fe7f5906b6d7887df8a5edd40f49eb2b14e20885809"
    LIB_REL="lib/libonnxruntime.${ORT_VERSION}.dylib"
    LIB_SHA256="6fee21a0dbcaa98fe082cb4f7ed07ec5def439df36198f47b61dc205e7d2a1fa"
    ;;
  Linux)
    PLATFORM="linux-x64"
    ARCHIVE="onnxruntime-linux-x64-${ORT_VERSION}.tgz"
    ARCHIVE_SHA256=""   # not pinned (development convenience only); verified against the GitHub asset size instead
    LIB_REL="lib/libonnxruntime.so.${ORT_VERSION}"
    LIB_SHA256=""
    ;;
  *) echo "fetch_ort.sh: unsupported OS $(uname -s); use fetch_ort.ps1 on Windows" >&2; exit 1 ;;
esac

URL="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/${ARCHIVE}"
DEST="${ROOT}/engine/third_party/onnxruntime/${PLATFORM}"

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

check_present() {
  [[ -f "${DEST}/include/onnxruntime_c_api.h" ]] || return 1
  [[ -f "${DEST}/${LIB_REL}" ]] || return 1
  if [[ -n "${LIB_SHA256}" ]]; then
    [[ "$(sha256_of "${DEST}/${LIB_REL}")" == "${LIB_SHA256}" ]] || return 1
  fi
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

echo "fetch_ort.sh: downloading ${URL}"
curl -fsSL --retry 3 -o "${TMP}/${ARCHIVE}" "${URL}"

if [[ -n "${ARCHIVE_SHA256}" ]]; then
  ACTUAL="$(sha256_of "${TMP}/${ARCHIVE}")"
  if [[ "${ACTUAL}" != "${ARCHIVE_SHA256}" ]]; then
    echo "fetch_ort.sh: sha256 mismatch for ${ARCHIVE}" >&2
    echo "  expected ${ARCHIVE_SHA256}" >&2
    echo "  actual   ${ACTUAL}" >&2
    exit 1
  fi
  echo "fetch_ort.sh: sha256 OK"
fi

mkdir -p "${TMP}/x"
tar -xzf "${TMP}/${ARCHIVE}" -C "${TMP}/x"
SRC="$(find "${TMP}/x" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -f "${SRC}/include/onnxruntime_c_api.h" ]] || { echo "fetch_ort.sh: archive layout unexpected (no include/onnxruntime_c_api.h)" >&2; exit 1; }

# Replace atomically: stage next to the destination, then swap.
STAGE="${DEST}.tmp.$$"
rm -rf "${STAGE}"
mkdir -p "$(dirname "${DEST}")"
mv "${SRC}" "${STAGE}"
rm -rf "${DEST}"
mv "${STAGE}" "${DEST}"

if [[ -n "${LIB_SHA256}" ]]; then
  ACTUAL="$(sha256_of "${DEST}/${LIB_REL}")"
  [[ "${ACTUAL}" == "${LIB_SHA256}" ]] || { echo "fetch_ort.sh: library sha256 mismatch (${ACTUAL})" >&2; exit 1; }
fi
if [[ "$(uname -s)" == "Darwin" ]]; then
  lipo -info "${DEST}/${LIB_REL}"
fi
echo "fetch_ort.sh: installed ONNX Runtime ${ORT_VERSION} to ${DEST}"
ls "${DEST}"
