#ifndef SHADOWDESK_FFMPEG_SUPPORT_H
#define SHADOWDESK_FFMPEG_SUPPORT_H

// Umbrella for the FFmpeg APIs the H.264 decoder needs. Development builds
// link Homebrew FFmpeg from /opt/homebrew; the packaged .app embeds the same
// dylibs (see Scripts/make-app.sh).
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/frame.h>
#include <libavutil/pixdesc.h>

#endif
