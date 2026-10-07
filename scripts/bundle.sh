#!/bin/sh
# Builds a release binary and wraps it in an ad-hoc signed Bitamp.app.
#
#   scripts/bundle.sh                                # this Mac's architecture
#   scripts/bundle.sh --universal --version 1.2.3    # Apple Silicon + Intel, stamped 1.2.3
set -eu
cd "$(dirname "$0")/.."

universal=0
version=""
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) universal=1 ;;
        --version) version="$2"; shift ;;
        *) echo "usage: scripts/bundle.sh [--universal] [--version X.Y.Z]" >&2; exit 2 ;;
    esac
    shift
done

set --
if [ "$universal" = 1 ]; then set -- --arch arm64 --arch x86_64; fi
swift build -c release "$@"
bindir="$(swift build -c release "$@" --show-bin-path)"
bin="$bindir/Bitamp"

app=Bitamp.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Bitamp"
# The package's resources (Basic Pitch's model), where BasicPitch.modelURL() looks.
cp -R "$bindir/Bitamp_BitampKit.bundle" "$app/Contents/Resources/"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ -n "$version" ]; then
    plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
    # The build number must be numbers and dots, so drop a pre-release suffix like "-beta.1".
    plutil -replace CFBundleVersion -string "${version%%-*}" "$app/Contents/Info.plist"
fi
swift scripts/make-icon.swift "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"

echo "Built $app"
