#!/bin/sh
# Packages Apple Music as a Pak of its own: "Apple Music Helper.bitpak", whose program is an
# app bundle (Helper.app) signed with a team identity and carrying a provisioning profile,
# which is what lets MusicKit use it. make-pak.sh can't do this: it packages a bare program.
#
#   scripts/make-applemusic-pak.sh                  # under Bitamp's own App ID
#   BUNDLE_ID=com.you.AppleMusicPak PROFILE=~/Downloads/Pak.provisionprofile \
#       scripts/make-applemusic-pak.sh              # under an App ID of your own
#
# Then drop the .bitpak on Bitamp (or copy it to ~/Library/Application Support/Bitamp/Paks/).
set -eu
cd "$(dirname "$0")/.."
identity="${IDENTITY:-Developer ID Application: RYAN NICHOLAS ROMANOSKY (KL362RST7H)}"
team="${TEAM:-KL362RST7H}"
bundle_id="${BUNDLE_ID:-com.ryanromanov.Bitamp}"
profile="${PROFILE:-Resources/Bitamp.provisionprofile}"
product=BitampAppleMusicHelper
manifest=Sources/$product/helper-pak.json

swift build -c release --product "$product"
bin="$(swift build -c release --show-bin-path)/$product"

name=$(plutil -extract name raw "$manifest")
executable=$(plutil -extract executable raw "$manifest")
version=$(plutil -extract version raw "$manifest")
pak="$name.bitpak"
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
<key>NSAppleMusicUsageDescription</key><string>Bitamp plays songs from your Apple Music library and the Apple Music catalog.</string>
</dict></plist>
PLIST
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
codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" "$helper"
rm -f "$entitlements"
cp "$manifest" "$pak/pak.json"
[ -x "$pak/$executable" ] || { echo "The manifest's executable $executable isn't in the package." >&2; exit 1; }
codesign -dv "$helper" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" || true
echo "Built $PWD/$pak (bundle id $bundle_id)"
