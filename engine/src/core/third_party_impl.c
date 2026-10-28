/* Single translation unit holding the implementations of the header-only
 * C libraries so they are compiled exactly once. */
#define DR_WAV_IMPLEMENTATION
#include "dr_libs/dr_wav.h"

#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#include "miniaudio/miniaudio.h"
