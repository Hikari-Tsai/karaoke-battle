#!/usr/bin/env bash
# Configure + build the C++ engine with CMake/Ninja and run `ke_cli gpu` as a smoke test.
#
#   scripts/build_engine.sh [--clean] [--debug] [--no-smoke]
#
# macOS builds a universal (arm64 + x86_64) libkaraoke_engine.dylib and verifies it with
# lipo. Output: engine/build/{libkaraoke_engine.dylib|libkaraoke_engine.so, ke_cli}.
# Override the build directory with KE_BUILD_DIR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${ROOT}/engine"
BUILD_DIR="${KE_BUILD_DIR:-${ENGINE}/build}"
BUILD_TYPE="Release"
CLEAN=0
SMOKE=1
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --debug) BUILD_TYPE="Debug" ;;
    --no-smoke) SMOKE=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

command -v cmake >/dev/null || { echo "build_engine.sh: cmake not found (brew install cmake)" >&2; exit 1; }
command -v ninja >/dev/null || { echo "build_engine.sh: ninja not found (brew install ninja)" >&2; exit 1; }

# Headers are needed at configure time.
"${ROOT}/scripts/fetch_ort.sh"

if [[ ${CLEAN} -eq 1 ]]; then
  rm -rf "${BUILD_DIR}"
fi

EXTRA=()
if [[ "$(uname -s)" == "Darwin" ]]; then
  EXTRA+=("-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64" "-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0")
fi

cmake -S "${ENGINE}" -B "${BUILD_DIR}" -G Ninja -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" "${EXTRA[@]}"
cmake --build "${BUILD_DIR}" --parallel

if [[ "$(uname -s)" == "Darwin" ]]; then
  LIB="${BUILD_DIR}/libkaraoke_engine.dylib"
  lipo -info "${LIB}"
  for arch in arm64 x86_64; do
    lipo "${LIB}" -verify_arch "${arch}" || { echo "build_engine.sh: ${LIB} is missing ${arch}" >&2; exit 1; }
  done
  echo "build_engine.sh: universal check OK"
else
  LIB="${BUILD_DIR}/libkaraoke_engine.so"
fi
ls -la "${LIB}" "${BUILD_DIR}/ke_cli"

if [[ ${SMOKE} -eq 1 ]]; then
  echo "build_engine.sh: smoke test - ke_cli gpu"
  "${BUILD_DIR}/ke_cli" gpu
fi
echo "build_engine.sh: done"
