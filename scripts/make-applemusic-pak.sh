#!/bin/sh
# Packages Apple Music, which comes with Bitamp as a Pak of its own, as "Apple Music.bitpak":
# its program is an app bundle (Helper.app) signed with a team identity and carrying a
# provisioning profile, which is what lets MusicKit use it. make-pak.sh can't do this: it
# packages a bare program. scripts/bundle.sh runs this and puts the result in the app.
#
#   scripts/make-applemusic-pak.sh [--universal] [--sign IDENTITY] [--out DIR] [--version X.Y.Z]
#
# Without --sign it signs with the Developer ID below. `--sign -` signs ad hoc, without the
# profile: library songs play, the catalog doesn't. Set BUNDLE_ID, PROFILE and TEAM to build
# under an App ID of your own (the profile must be for that App ID, with MusicKit enabled).
# --version stamps the Pak (bundle.sh passes the app's), so Bitamp updates an installed copy when
# the app brings a newer one; without it the manifest's version is used.
set -eu
cd "$(dirname "$0")/.."

identity="${IDENTITY:-Developer ID Application: RYAN NICHOLAS ROMANOSKY (KL362RST7H)}"
team="${TEAM:-KL362RST7H}"
bundle_id="${BUNDLE_ID:-com.ryanromanov.Bitamp}"
profile="${PROFILE:-Resources/Bitamp.provisionprofile}"
out=.
arch=
version=
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) arch="--arch arm64 --arch x86_64" ;;
        --sign) identity="$2"; shift ;;
        --out) out="$2"; shift ;;
        --version) version="$2"; shift ;;
        *) echo "usage: $0 [--universal] [--sign IDENTITY] [--out DIR] [--version X.Y.Z]" >&2; exit 64 ;;
    esac
    shift
done
product=BitampAppleMusicHelper
manifest=Sources/$product/helper-pak.json

# shellcheck disable=SC2086
swift build -c release --product "$product" $arch
# shellcheck disable=SC2086
bin="$(swift build -c release $arch --show-bin-path)/$product"

name=$(plutil -extract name raw "$manifest")
executable=$(plutil -extract executable raw "$manifest")
# A pre-release suffix like "-beta.1" is dropped: versions are compared as numbers.
version="${version:-$(plutil -extract version raw "$manifest")}"
version="${version%%-*}"
pak="$out/$name.bitpak"
helper="$pak/Helper.app"
rm -rf "$pak"
mkdir -p "$helper/Contents/MacOS"
cp "$bin" "$helper/Contents/MacOS/$product"
cat > "$helper/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$product</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleMusicUsageDescription</key><string>Bitamp plays songs from your Apple Music library and catalog.</string>
</dict></plist>
PLIST
if [ "$identity" = "-" ]; then
    codesign --force --options runtime --sign - "$helper"
else
    cp "$profile" "$helper/Contents/embedded.provisionprofile"
    entitlements="$(mktemp -t entitlements).plist"
    cat > "$entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.application-identifier</key><string>$team.$bundle_id</string>
<key>com.apple.developer.team-identifier</key><string>$team</string>
</dict></plist>
PLIST
    # A secure timestamp is required for notarization.
    codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" "$helper"
    rm -f "$entitlements"
fi
cp "$manifest" "$pak/pak.json"
plutil -replace version -string "$version" "$pak/pak.json"
[ -x "$pak/$executable" ] || { echo "The manifest's executable $executable isn't in the package." >&2; exit 1; }
echo "Built $pak (bundle id $bundle_id)"
