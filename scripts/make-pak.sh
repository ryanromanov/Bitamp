#!/bin/sh
# Packages an Expansion Pak written in Swift as <Name>.bitpak: its pak.json plus the
# program it names. Double-click the result, or drop it on Bitamp, to install it.
#
#   scripts/make-pak.sh                      # the Pak in this package (here, the demo → Demo.bitpak)
#   scripts/make-pak.sh MyPak                # the executable target MyPak, with Sources/MyPak/pak.json
#   scripts/make-pak.sh --universal [MyPak]  # Apple Silicon + Intel
#
# It works on the Swift package in the current directory, or on Bitamp's when run from
# elsewhere. Copy it into your own Pak's package and it works there too. The manifest is
# Sources/<target>/pak.json, or pak.json next to Package.swift. Without a target name, the
# one target with a pak.json is used. See docs/PAK-SDK.md.
set -eu

universal=no
product=
for arg in "$@"; do
    case "$arg" in
        --universal) universal=yes ;;
        -*) echo "usage: $0 [--universal] [target]" >&2; exit 64 ;;
        *) product="$arg" ;;
    esac
done

if [ ! -f Package.swift ]; then cd "$(dirname "$0")/.."; fi
if [ ! -f Package.swift ]; then echo "Run this from your Pak's Swift package." >&2; exit 1; fi

if [ -z "$product" ]; then
    found=$(ls Sources/*/pak.json 2>/dev/null || true)
    case "$(printf '%s\n' "$found" | grep -c .)" in
        1) product=$(basename "$(dirname "$found")") ;;
        0) echo "No Sources/<target>/pak.json here; name the target: $0 <target>" >&2; exit 1 ;;
        *) echo "More than one target has a pak.json; name one: $0 <target>" >&2; exit 1 ;;
    esac
fi
if [ -f "Sources/$product/pak.json" ]; then
    manifest="Sources/$product/pak.json"
elif [ -f pak.json ]; then
    manifest=pak.json
else
    echo "No pak.json in Sources/$product or next to Package.swift." >&2
    exit 1
fi

set --
if [ "$universal" = yes ]; then set -- --arch arm64 --arch x86_64; fi
swift build -c release --product "$product" "$@"
bin="$(swift build -c release "$@" --show-bin-path)/$product"

name=$(plutil -extract name raw "$manifest")
executable=$(plutil -extract executable raw "$manifest")
pak="$name.bitpak"
rm -rf "$pak"
mkdir -p "$pak"
cp "$manifest" "$pak/pak.json"
cp "$bin" "$pak/$executable"
# Ad-hoc signed, as Apple Silicon requires of anything it runs. Sign it with your
# Developer ID instead to distribute it.
codesign --force --sign - "$pak/$executable"
echo "Built $PWD/$pak"
echo "Check it with: /Applications/Bitamp.app/Contents/MacOS/Bitamp --check-pak \"$pak\" (Bitamp after 0.5.0)"
