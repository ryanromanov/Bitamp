#!/bin/sh
# Builds a release binary and wraps it in a signed Bitamp.app, ad-hoc unless --sign names
# an identity. It always signs with the hardened runtime, which notarization requires.
# Apple Music comes inside the app as a Pak (scripts/make-applemusic-pak.sh), which Bitamp installs
# on first launch; signed with an identity, it also gets Resources/Bitamp.provisionprofile.
#
#   scripts/bundle.sh                                # this Mac's architecture
#   scripts/bundle.sh --universal --version 1.2.3    # Apple Silicon + Intel, stamped 1.2.3
#   scripts/bundle.sh --sign "Developer ID Application: Name (TEAMID)"   # then scripts/notarize.sh
set -eu
cd "$(dirname "$0")/.."

universal=0
version=""
identity="-"
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) universal=1 ;;
        --version) version="$2"; shift ;;
        --sign) identity="$2"; shift ;;
        *) echo "usage: scripts/bundle.sh [--universal] [--version X.Y.Z] [--sign IDENTITY]" >&2; exit 2 ;;
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
# Apple Music is a Pak whose program is a helper app, signed before the app that holds it. Its
# provisioning profile lets it claim the App ID MusicKit needs to reach the catalog; it's only
# valid for team KL362RST7H, so to sign as another team, set BUNDLE_ID, PROFILE and TEAM
# (see make-applemusic-pak.sh).
mkdir -p "$app/Contents/Resources/Paks"
# The Pak takes the app's version, so each release brings an update of it.
set --
if [ "$universal" = 1 ]; then set -- --universal; fi
if [ -n "$version" ]; then set -- "$@" --version "$version"; fi
scripts/make-applemusic-pak.sh "$@" --sign "$identity" --out "$app/Contents/Resources/Paks"
if [ "$identity" = "-" ]; then
    codesign --force --options runtime --sign - "$app"
else
    # A secure timestamp is required for notarization; ad-hoc signatures can't have one.
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi

echo "Built $app"
