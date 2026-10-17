#!/bin/bash
# Assembles dist/ShadowDesk.app from the SPM build products.
#
# A real bundle (rather than a bare executable) is what gives the window
# keyboard focus and lets the Metal view take over the pointer; the WebRTC
# framework is embedded and the rpath is fixed up accordingly.
set -euo pipefail
cd "$(dirname "$0")/.."

export GIT_SSL_NO_VERIFY="${GIT_SSL_NO_VERIFY:-1}"

CONFIG="${CONFIG:-release}"
APP="dist/ShadowDesk.app"

echo "== building ($CONFIG) =="
swift build -c "$CONFIG" --product ShadowDesk
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "== assembling $APP =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp "$BIN/ShadowDesk" "$APP/Contents/MacOS/ShadowDesk"
cp Scripts/Info.plist "$APP/Contents/Info.plist"
cp Scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$APP/Contents/Frameworks/WebRTC.framework"
cp -R "$BIN/WebRTC.framework" "$APP/Contents/Frameworks/WebRTC.framework"

FRAMEWORK="$APP/Contents/Frameworks/WebRTC.framework/Versions/A/WebRTC"
if [ -f "$FRAMEWORK" ]; then
    install_name_tool -id "@rpath/WebRTC.framework/Versions/A/WebRTC" "$FRAMEWORK"
fi

if ! otool -l "$APP/Contents/MacOS/ShadowDesk" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/ShadowDesk"
fi

# Ad-hoc signature is enough for local use; replace with a Developer ID for
# distribution.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || codesign --force --deep --sign - "$APP"

echo "== built $APP =="
echo "run:  open $APP            (or: open $APP --args --auto)"
