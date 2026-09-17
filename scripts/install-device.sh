#!/usr/bin/env bash
# Build FreeTube for a connected iPhone with your own Apple Developer team and install it.
#
#   DEVELOPMENT_TEAM=XXXXXXXXXX scripts/install-device.sh            # first connected iPhone
#   DEVELOPMENT_TEAM=XXXXXXXXXX scripts/install-device.sh <udid>     # a specific device
#
# Requirements: Xcode with the license accepted, the iPhone connected over USB (or paired over
# Wi-Fi), unlocked, trusted, with Developer Mode on (Settings › Privacy & Security). The first
# launch on the phone asks you to trust the developer certificate (Settings › General › VPN &
# Device Management). Automatic signing registers the device and the bundle ID for your team.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your 10-character Apple Developer team ID}"

UDID="${1:-}"
if [[ -z "$UDID" ]]; then
  UDID="$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
for dev in d.get("result",{}).get("devices",[]):
    hw=dev.get("hardwareProperties",{})
    if hw.get("platform")=="iOS" and hw.get("reality")=="physical" and dev.get("connectionProperties",{}).get("tunnelState")!="unavailable":
        print(dev["hardwareProperties"]["udid"]); break')"
fi
[[ -n "$UDID" ]] || { echo "No connected iPhone found. Plug it in, unlock it, tap Trust."; exit 1; }
echo "Device: $UDID"

DERIVED="$HOME/Library/Developer/Xcode/DerivedData/FreeTube-device"
xcodebuild build \
  -project FreeTube/FreeTube.xcodeproj \
  -scheme FreeTube \
  -configuration Release \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  | grep -E '(error: |warning: .*sign|\*\* BUILD)' || true

APP="$(find "$DERIVED/Build/Products/Release-iphoneos" -maxdepth 1 -name 'FreeTube.app' -print -quit)"
[[ -n "$APP" ]] || { echo "Build failed — see output above."; exit 1; }
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" com.leshko.freetube || true
echo "Installed. If the app refuses to open, trust the developer profile in Settings › General › VPN & Device Management."
