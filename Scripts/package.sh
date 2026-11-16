#!/usr/bin/env bash
#
# Wraps the last Release build into a sideloadable IPA, fakesigned with the
# HealthKit entitlements so the signer (ESign) carries them onto the device.
#
# Usage:  ./Scripts/package.sh   (from the repo root, after xcodebuild)

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release-iphoneos/HRRelay.app"

if [ ! -f "$APP/HRRelay" ]; then
    echo "error: $APP has no executable; the build failed."
    exit 1
fi

# A failed build leaves the previous binary behind. Refuse to ship it.
NEWEST_SOURCE="$(find Sources Support -type f \( -name '*.swift' -o -name '*.plist' -o -name '*.entitlements' \) -newer "$APP/HRRelay" -print -quit)"
if [ -n "$NEWEST_SOURCE" ]; then
    echo "error: $NEWEST_SOURCE is newer than the built binary; refusing to package stale code."
    exit 1
fi

# Without com.apple.developer.healthkit in the binary, HealthKit refuses every
# query on device. ldid embeds it; ESign re-signs on install.
ldid -SSupport/HRRelay.entitlements "$APP/HRRelay"
ldid -e "$APP/HRRelay" | grep -q 'com.apple.developer.healthkit' || {
    echo "error: entitlements did not embed."
    exit 1
}

rm -rf Payload HRRelay.ipa
mkdir Payload
cp -R "$APP" Payload/
zip -qr -X HRRelay.ipa Payload
rm -rf Payload

echo "HRRelay.ipa   $(du -h HRRelay.ipa | cut -f1)"
