#!/usr/bin/env bash
# Archive, sign for App Store Connect and upload a TestFlight build.
#
# Defaults match the paid Individual team that already ships 一一 (see poems/AGENTS.md).
# Override any of these if you are signing with a different team or key.
#
#   scripts/testflight.sh
#
#   DEVELOPMENT_TEAM=XXXXXXXXXX ASC_KEY_ID=ABCDEFGHIJ \
#   ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
#   ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_ABCDEFGHIJ.p8 \
#   scripts/testflight.sh
#
# One-time setup in App Store Connect (https://appstoreconnect.apple.com):
#   1. Users and Access › Integrations › Team Keys: create a key with the "App Manager" role.
#      Download the .p8 once, note Key ID and Issuer ID.
#   2. Apps › "+" › New App — the API on this account cannot CREATE apps (GET/UPDATE only).
#      Platform iOS, bundle ID `xyz.freetube.app`, unique name (e.g. "freetube.app"),
#      SKU `freetube-xyz`. Without this record the upload fails with
#      "No suitable application records were found".
#   3. After the first upload finishes processing (~10 min), TestFlight › Internal Testing: add a
#      group and testers. Internal testers must be members of your App Store Connect team
#      (Users and Access › "+", role Developer or App Manager); up to 100, no Apple review.
#      External testing / public links go through Beta App Review, which this kind of app is
#      unlikely to pass — keep it internal.
#
# Automatic signing with the API key creates the Apple Distribution certificate and the App
# Store provisioning profile on demand (-allowProvisioningUpdates). The build number is the
# UTC timestamp so every upload is unique; MARKETING_VERSION comes from the project.
set -euo pipefail

cd "$(dirname "$0")/.."
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-8A52V3MFHD}"
ASC_KEY_ID="${ASC_KEY_ID:-X3HPUJ2HZ6}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-ea3f9eb6-9efb-4a16-aadb-3d659f3d7553}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[[ -f "$ASC_KEY_PATH" ]] || { echo "API key not found at $ASC_KEY_PATH"; exit 1; }

BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
OUT="$HOME/Library/Developer/Xcode/Archives/FreeTube-TestFlight"
mkdir -p "$OUT"
ARCHIVE="$OUT/FreeTube-$BUILD_NUMBER.xcarchive"
EXPORT_DIR="$OUT/export-$BUILD_NUMBER"
# Reuse the checkout that already has the Xcode 27 LNPopupController header-path patch.
# A fresh DerivedData re-resolves the package and the archive fails. See AGENTS.md.
DERIVED="${DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/FreeTube-eywdjbqyvkyzspczlwloasunrlwr}"
# Archive/export must use the Xcode-logged-in Apple ID. Passing the ASC API key here
# triggers "Cloud signing permission error" — this key cannot mint cloud-managed
# Distribution certificates. altool upload is the only step that uses the key.
SIGN=(-allowProvisioningUpdates)

echo "== Archiving build $BUILD_NUMBER"
xcodebuild archive \
  -project FreeTube/FreeTube.xcodeproj \
  -scheme FreeTube \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  "${SIGN[@]}" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  | grep -E '(error: |warning: .*(sign|provision)|\*\* ARCHIVE)' || true
[[ -d "$ARCHIVE" ]] || { echo "Archive failed."; exit 1; }

PLIST="$OUT/export-options.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PL

echo "== Exporting App Store IPA"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$PLIST" \
  -exportPath "$EXPORT_DIR" \
  "${SIGN[@]}" \
  | grep -E '(error: |\*\* EXPORT)' || true
IPA="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' -print -quit)"
[[ -n "$IPA" ]] || { echo "Export failed."; exit 1; }

echo "== Uploading $IPA"
xcrun altool --upload-app --type ios --file "$IPA" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "== Uploaded build $BUILD_NUMBER. Processing takes ~5–15 minutes; then add it to an Internal Testing group in TestFlight."
