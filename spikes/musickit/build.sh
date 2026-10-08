#!/bin/sh
# Builds MusicKitSpike.app, signed ad-hoc unless --sign names an identity.
#
#   spikes/musickit/build.sh
#   spikes/musickit/build.sh --sign "Developer ID Application: Name (TEAMID)"
#   spikes/musickit/MusicKitSpike.app/Contents/MacOS/MusicKitSpike [--auto "search term"]
set -eu
cd "$(dirname "$0")"

identity="-"
if [ "${1:-}" = "--sign" ]; then identity="$2"; fi

swift build -c release
bin="$(swift build -c release --show-bin-path)/MusicKitSpike"
app=MusicKitSpike.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
if [ "$identity" = "-" ]; then
    codesign --force --options runtime --sign - "$app"
else
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign -dv "$app" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" || true
echo "Built $app"
