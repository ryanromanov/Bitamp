#!/bin/sh
# Sends a Developer ID-signed Bitamp.app to Apple's notary service, waits for the verdict,
# and staples the ticket to the app so Gatekeeper accepts it offline.
#
#   scripts/notarize.sh [Bitamp.app]
#
# Credentials, either:
#   NOTARY_PROFILE=name       a profile saved once with `xcrun notarytool store-credentials`
#   NOTARY_KEY=path.p8 NOTARY_KEY_ID=… NOTARY_ISSUER_ID=…   an App Store Connect API key (CI)
set -eu
cd "$(dirname "$0")/.."

app="${1:-Bitamp.app}"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    set -- --keychain-profile "$NOTARY_PROFILE"
elif [ -n "${NOTARY_KEY:-}" ]; then
    set -- --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
else
    echo "Set NOTARY_PROFILE, or NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER_ID." >&2
    exit 2
fi

# The notary service takes a zip, but the ticket is stapled to the app itself.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ditto -c -k --keepParent "$app" "$work/upload.zip"

xcrun notarytool submit "$work/upload.zip" "$@" --wait --timeout 30m \
    --output-format json > "$work/result.json" || true
cat "$work/result.json"; echo
status="$(plutil -extract status raw "$work/result.json" 2>/dev/null || echo unknown)"
if [ "$status" != "Accepted" ]; then
    id="$(plutil -extract id raw "$work/result.json" 2>/dev/null || true)"
    if [ -n "$id" ]; then xcrun notarytool log "$id" "$@" || true; fi
    echo "Notarization failed: $status" >&2
    exit 1
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
echo "Notarized $app"
