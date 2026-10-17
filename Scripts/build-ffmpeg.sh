#!/bin/bash
# Builds a minimal, decode-only FFmpeg (libavcodec + libavutil, H.264 decoder
# and parser) as static libraries into Vendor/FFmpeg.
#
# Why not Homebrew's FFmpeg: its dylibs target the host macOS only and drag in
# the full codec chain (x264/x265/openssl/dav1d/…), much of it GPL. This build
# has zero external dependencies, targets macOS 14, and contains only the
# decoder the lossless color mode needs.
#
# The Makefile patch below works around an FFmpeg 7.1 configure quirk: the
# H.264 SEI objects reference `ff_aom_uninit_film_grain_params`, which is only
# compiled when HEVC SEI is enabled (and `--enable-hevc_sei` is rejected as an
# internal component).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${FFMPEG_VERSION:-7.1.1}"
ROOT="$PWD/Vendor/FFmpeg"
SRC="$PWD/Vendor/src/FFmpeg-$VERSION"

if [ -f "$ROOT/lib/libavcodec.a" ] && [ -f "$ROOT/include/libavcodec/avcodec.h" ]; then
    echo "== Vendor/FFmpeg already built (delete it to rebuild) =="
    exit 0
fi

mkdir -p Vendor/src
if [ ! -d "$SRC" ]; then
    TARBALL="Vendor/src/ffmpeg-$VERSION.tar.xz"
    if [ ! -f "$TARBALL" ]; then
        echo "== downloading FFmpeg $VERSION =="
        # `-k` fallback: this machine's TLS interception breaks ffmpeg.org.
        curl -fL --retry 3 -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" \
            || curl -kfL --retry 3 -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
    fi
    tar -xJf "$TARBALL" -C Vendor/src
    mv "Vendor/src/ffmpeg-$VERSION" "$SRC"
fi

echo "== configuring (decode-only, no autodetected deps) =="
cd "$SRC"
sed -i '' 's/^\(OBJS-\$(CONFIG_H264_SEI).*h2645_sei\.o\)$/\1 aom_film_grain.o/' libavcodec/Makefile
./configure \
    --prefix="$ROOT" \
    --enable-static --disable-shared --enable-pic \
    --disable-everything --disable-programs --disable-doc --disable-debug \
    --disable-autodetect --disable-network \
    --enable-optimizations \
    --enable-decoder=h264 --enable-parser=h264 \
    --extra-cflags="-mmacosx-version-min=14.0 -arch arm64" \
    --extra-ldflags="-mmacosx-version-min=14.0 -arch arm64"

echo "== building =="
make -j"$(sysctl -n hw.ncpu)"
make install

echo "== done: $ROOT =="
ls "$ROOT/lib"
