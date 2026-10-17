#!/bin/bash
# Build and run the shadowift spike (macOS host).
#
# GIT_SSL_NO_VERIFY=1: this machine sits behind a TLS-intercepting mirror and
# the system git (LibreSSL) rejects its certificate. Harmless otherwise; drop
# it if your git can reach github.com directly.
set -euo pipefail
cd "$(dirname "$0")"

export GIT_SSL_NO_VERIFY="${GIT_SSL_NO_VERIFY:-1}"

echo "== resolve (downloads the prebuilt libwebrtc xcframework on first run, ~45 MB) =="
swift package resolve

echo "== build =="
swift build

BIN="$(swift build --show-bin-path)"
echo "== run loopback =="
DYLD_FRAMEWORK_PATH="$BIN" "$BIN/loopback" | tee output/loopback.txt
echo "== run codecprobe =="
DYLD_FRAMEWORK_PATH="$BIN" "$BIN/codecprobe" | tee output/codecprobe.txt
