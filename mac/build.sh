#!/bin/bash
# Builds ClaudeSwitch.app for macOS 11+ as a universal binary (Apple silicon and Intel),
# with nothing but the Xcode command line tools (xcode-select --install).
# Output: mac/build/ClaudeSwitch.app and mac/build/ClaudeSwitch-mac.zip
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.1}"
OUT=build
APP="$OUT/ClaudeSwitch.app"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos11" -o "$OUT/ClaudeSwitch-$arch" ClaudeSwitch.swift
done
lipo -create -output "$APP/Contents/MacOS/ClaudeSwitch" "$OUT/ClaudeSwitch-arm64" "$OUT/ClaudeSwitch-x86_64"
rm "$OUT/ClaudeSwitch-arm64" "$OUT/ClaudeSwitch-x86_64"

sed "s/@VERSION@/$VERSION/g" Info.plist > "$APP/Contents/Info.plist"

# App icon from AppIcon.png (the 256 px image of ../claudeswitch.ico).
ICONSET="$OUT/ClaudeSwitch.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256; do
    sips -z $size $size AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
for size in 16 32 128; do
    sips -z $((size * 2)) $((size * 2)) AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/ClaudeSwitch.icns"
rm -rf "$ICONSET"

# Ad-hoc signature: required to run on Apple silicon. Not a Developer ID, so Gatekeeper
# still asks for confirmation on first launch.
codesign --force --sign - "$APP"

ditto -c -k --keepParent "$APP" "$OUT/ClaudeSwitch-mac.zip"
echo "Build OK: $APP"
