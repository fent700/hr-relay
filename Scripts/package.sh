#!/usr/bin/env bash
#
# Wraps the last Release build into a sideloadable IPA, ad-hoc signed with the
# HealthKit entitlements so the signer (ESign) carries them onto the device.
#
# Usage:  ./Scripts/package.sh   (from the repo root, after xcodebuild)

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release-iphoneos/HRRelay.app"
WATCH="build/Build/Products/Release-watchos/HRRelayWatch.app"

if [ ! -f "$APP/HRRelay" ]; then
    echo "error: $APP has no executable; the build failed."
    exit 1
fi

if [ ! -f "$WATCH/HRRelayWatch" ]; then
    echo "error: $WATCH has no executable; the watch build failed."
    exit 1
fi

# Series 3 runs armv7k. Without that slice the watch refuses the install.
ARCHS_FOUND="$(lipo -archs "$WATCH/HRRelayWatch")"
echo "watch slices: $ARCHS_FOUND"
case " $ARCHS_FOUND " in
    *" armv7k "*) ;;
    *) echo "error: watch binary has no armv7k slice; it won't install on a Series 3."; exit 1 ;;
esac

# A failed build leaves the previous binary behind. Refuse to ship it.
NEWEST_SOURCE="$(find Sources WatchSources Support -type f \( -name '*.swift' -o -name '*.plist' -o -name '*.entitlements' \) -newer "$APP/HRRelay" -print -quit)"
if [ -n "$NEWEST_SOURCE" ]; then
    echo "error: $NEWEST_SOURCE is newer than the built binary; refusing to package stale code."
    exit 1
fi

# Without com.apple.developer.healthkit in the binary, HealthKit refuses every
# query on device. An ad-hoc signature carries it; ESign re-signs on install.
# Apple's codesign, not ldid: ldid 2.1.5 segfaults on the armv7k watch slice.
# Each binary is signed outside its bundle so no _CodeSignature folder appears.
SCRATCH="$(mktemp -d)"
for BIN in "$APP/HRRelay" "$WATCH/HRRelayWatch"; do
    cp "$BIN" "$SCRATCH/bin"
    codesign --force --sign - --entitlements Support/HRRelay.entitlements "$SCRATCH/bin"
    codesign -d --entitlements - "$SCRATCH/bin" 2>/dev/null | grep -q 'com.apple.developer.healthkit' || {
        echo "error: entitlements did not embed in $BIN."
        exit 1
    }
    cp "$SCRATCH/bin" "$BIN"
done
rm -rf "$SCRATCH"

rm -rf Payload HRRelay.ipa
mkdir Payload
cp -R "$APP" Payload/
mkdir -p Payload/HRRelay.app/Watch
cp -R "$WATCH" Payload/HRRelay.app/Watch/
zip -qr -X HRRelay.ipa Payload
rm -rf Payload

echo "HRRelay.ipa   $(du -h HRRelay.ipa | cut -f1)"
