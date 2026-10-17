#include "ffmpeg_shim.h"

// The header does all the work; this translation unit only exists so the
// target has something to compile.
unsigned shadowdesk_ffmpeg_version(void) {
    return avcodec_version();
}
