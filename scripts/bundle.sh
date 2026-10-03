#!/bin/sh
# Builds a release binary and wraps it in an ad-hoc signed Bitamp.app.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
bin="$(swift build -c release --show-bin-path)/Bitamp"

app=Bitamp.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Bitamp"
cp Resources/Info.plist "$app/Contents/Info.plist"
swift scripts/make-icon.swift "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"

echo "Built $app"
