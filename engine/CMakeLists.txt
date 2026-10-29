cmake_minimum_required(VERSION 3.21)

# Universal macOS binary must be requested before project()
if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "" FORCE)
endif()
if(APPLE AND NOT CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "" FORCE)
endif()

project(karaoke_engine LANGUAGES C CXX VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# ---------------------------------------------------------------------------
# ONNX Runtime headers (library is loaded dynamically at run time, never linked)
# scripts/fetch_ort.sh downloads them into third_party/onnxruntime/<platform>
# ---------------------------------------------------------------------------
if(NOT KE_ORT_INCLUDE_DIR)
  if(APPLE)
    set(KE_ORT_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/onnxruntime/osx-universal2/include")
  elseif(WIN32)
    set(KE_ORT_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/onnxruntime/win-x64/include")
  else()
    set(KE_ORT_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/onnxruntime/linux-x64/include")
  endif()
endif()
if(NOT EXISTS "${KE_ORT_INCLUDE_DIR}/onnxruntime_c_api.h")
  message(FATAL_ERROR "ONNX Runtime headers not found at ${KE_ORT_INCLUDE_DIR}. Run scripts/fetch_ort.sh first or set -DKE_ORT_INCLUDE_DIR.")
endif()

set(KE_SOURCES
  src/api.cpp
  src/core/error.cpp
  src/core/ort_runtime.cpp
  src/core/wav.cpp
  src/core/resample.cpp
  src/core/gpu_info.cpp
  src/core/third_party_impl.c
  src/dsp/stft.cpp
  src/dsp/mpm.cpp
  src/dsp/hall_reverb.cpp
  src/dsp/reverb_api.cpp
  third_party/cloudseed/DSP/Biquad.cpp
  third_party/cloudseed/DSP/RandomBuffer.cpp
  src/models/swiftf0.cpp
  src/models/mdx.cpp
  src/models/game.cpp
  src/models/slicer.cpp
  src/models/beat_this.cpp
  src/audio/audio_engine.cpp
)

add_library(karaoke_engine SHARED ${KE_SOURCES})
target_compile_definitions(karaoke_engine PRIVATE KE_BUILD_SHARED=1)
# Vendored Cloud Seed sources: upstream warnings only.
set_source_files_properties(third_party/cloudseed/DSP/Biquad.cpp third_party/cloudseed/DSP/RandomBuffer.cpp
  PROPERTIES COMPILE_OPTIONS "$<IF:$<CXX_COMPILER_ID:MSVC>,/w,-w>")
target_include_directories(karaoke_engine
  PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/include
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
          ${CMAKE_CURRENT_SOURCE_DIR}/third_party
          ${KE_ORT_INCLUDE_DIR}
)
set_target_properties(karaoke_engine PROPERTIES
  OUTPUT_NAME "karaoke_engine"
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
)

if(MSVC)
  target_compile_options(karaoke_engine PRIVATE /W3 /utf-8 /bigobj)
  target_compile_definitions(karaoke_engine PRIVATE _CRT_SECURE_NO_WARNINGS NOMINMAX WIN32_LEAN_AND_MEAN _USE_MATH_DEFINES)
  target_link_libraries(karaoke_engine PRIVATE dxgi ole32)
else()
  target_compile_options(karaoke_engine PRIVATE -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare)
endif()

if(APPLE)
  target_link_libraries(karaoke_engine PRIVATE
    "-framework CoreAudio" "-framework AudioToolbox" "-framework AudioUnit"
    "-framework CoreFoundation" "-framework Metal" "-framework IOKit" dl pthread)
elseif(UNIX)
  target_link_libraries(karaoke_engine PRIVATE dl pthread m)
endif()

# ---------------------------------------------------------------------------
# CLI used for development, numerical tests and CI smoke tests
# ---------------------------------------------------------------------------
add_executable(ke_cli tools/ke_cli.cpp)
target_link_libraries(ke_cli PRIVATE karaoke_engine)
target_include_directories(ke_cli PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/third_party)
if(APPLE)
  set_target_properties(ke_cli PROPERTIES BUILD_RPATH "@loader_path")
elseif(UNIX)
  set_target_properties(ke_cli PROPERTIES BUILD_RPATH "$ORIGIN")
endif()

install(TARGETS karaoke_engine ke_cli
  RUNTIME DESTINATION bin
  LIBRARY DESTINATION lib)
