#!/bin/sh
# Packages the demo Expansion Pak as Demo.bitpak: its pak.json plus the program it names.
# Double-click the result, or drop it on Bitamp, to install it.
#
#   scripts/make-pak.sh                  # this Mac's architecture
#   scripts/make-pak.sh --universal      # Apple Silicon + Intel
#
# A Pak of your own is the same shape: a folder named <Name>.bitpak with pak.json and
# your program. See docs/PAK-SDK.md.
set -eu
cd "$(dirname "$0")/.."

set --
if [ "${1:-}" = "--universal" ]; then set -- --arch arm64 --arch x86_64; fi
swift build -c release --product BitampDemoPak "$@"
bin="$(swift build -c release "$@" --show-bin-path)/BitampDemoPak"

pak=Demo.bitpak
manifest=Sources/BitampDemoPak/pak.json
executable=$(plutil -extract executable raw "$manifest")
rm -rf "$pak"
mkdir -p "$pak"
cp "$manifest" "$pak/pak.json"
cp "$bin" "$pak/$executable"
# Ad-hoc signed, as Apple Silicon requires of anything it runs.
codesign --force --sign - "$pak/$executable"
echo "Built $pak"
