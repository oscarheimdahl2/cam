#!/bin/bash
# Builds a distributable Cam: Release build, Developer ID signing, notarization, stapling and a DMG.
#
#   scripts/release.sh                 full release (needs the notarization profile, see below)
#   scripts/release.sh --skip-notarize build, sign and package only (to test the packaging; Gatekeeper will still warn)
#   BUILD_NUMBER=1795168971 scripts/release.sh   pin the build number (the extension version) instead of using the clock
#
# CI signs manually with two Developer ID provisioning profiles (the runner is not a registered development device):
#   APP_PROFILE_NAME / EXT_PROFILE_NAME = the profiles' names, already installed on the machine.
#
# In CI (.github/workflows/release.yml) the keychain profile is replaced by an App Store Connect API key:
#   ASC_KEY_PATH=<AuthKey.p8> ASC_KEY_ID=<id> ASC_ISSUER_ID=<issuer> scripts/release.sh
#
# One-time setup, in your own Terminal (so the password never ends up in a chat or a log):
#   xcrun notarytool store-credentials "cam-notary" --apple-id "<your apple id>" --team-id "<your team id>"
# It asks for an app-specific password (account.apple.com > Sign-In and Security > App-Specific Passwords).
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="cam-notary"
SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

# Notarization and provisioning credentials: an API key in CI, otherwise the keychain profile.
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  NOTARY_AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  XCODE_AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
else
  NOTARY_AUTH=(--keychain-profile "$PROFILE")
  XCODE_AUTH=()
fi

MANUAL_SIGNING=0
[[ -n "${APP_PROFILE_NAME:-}" && -n "${EXT_PROFILE_NAME:-}" ]] && MANUAL_SIGNING=1

TEAM_ID=$(sed -n 's/^ *TEAM_ID: *\([A-Z0-9]*\).*/\1/p' project.yml | head -1)
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' project.yml | head -1)
BUILD=${BUILD_NUMBER:-$(date +%s)}   # a new, higher number every time (macOS only replaces an installed extension with a higher one); pin it with BUILD_NUMBER=… to rebuild without forcing an extension update
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
[[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' certificate found in your keychain." >&2; exit 1; }

OUT="build/release/$VERSION"
ARCHIVE="$OUT/Cam.xcarchive"
EXPORT="$OUT/export"
DMG="$OUT/Cam-$VERSION.dmg"
echo "Cam $VERSION (build $BUILD), team $TEAM_ID"
echo "Signing as: $IDENTITY"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "== 1/6 Generate the project"
xcodegen generate >/dev/null

echo "== 2/6 Archive (Release)"
if [[ $MANUAL_SIGNING -eq 1 ]]; then
  ARCHIVE_SIGNING=(CAM_SIGN_STYLE=Manual "APP_PROFILE=$APP_PROFILE_NAME" "EXT_PROFILE=$EXT_PROFILE_NAME"
                   "CODE_SIGN_IDENTITY=Developer ID Application")
else
  ARCHIVE_SIGNING=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"})
fi
xcodebuild archive -project Cam.xcodeproj -scheme Cam -configuration Release \
  -archivePath "$ARCHIVE" "${ARCHIVE_SIGNING[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD" -quiet

echo "== 3/6 Export signed with Developer ID"
if [[ $MANUAL_SIGNING -eq 1 ]]; then
  SIGNING_KEYS="<key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key><dict>
    <key>com.oscarheimdahl.cam</key><string>$APP_PROFILE_NAME</string>
    <key>com.oscarheimdahl.cam.extension</key><string>$EXT_PROFILE_NAME</string>
  </dict>"
  EXPORT_AUTH=()
else
  SIGNING_KEYS="<key>signingStyle</key><string>automatic</string>"
  EXPORT_AUTH=(-allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"})
fi
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  $SIGNING_KEYS
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$EXPORT" ${EXPORT_AUTH[@]+"${EXPORT_AUTH[@]}"} -quiet
APP="$EXPORT/Cam.app"
codesign --verify --deep --strict "$APP"
"$(dirname "$0")/check-no-user-data.sh" "$APP"   # a fresh install must start empty

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  echo "== 4/6 Notarize the app (Apple scans it; usually a few minutes)"
  ditto -c -k --keepParent "$APP" "$OUT/Cam-notarize.zip"
  xcrun notarytool submit "$OUT/Cam-notarize.zip" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$APP"
else
  echo "== 4/6 Notarize: skipped"
fi

echo "== 5/6 Build the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/Cam.app"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Cam" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$DMG"
fi

echo "== 6/6 Verify"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -1
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | head -2 || true
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | head -2 || true
[[ $SKIP_NOTARIZE -eq 0 ]] && xcrun stapler validate "$DMG"
echo
echo "Done: $DMG"
shasum -a 256 "$DMG"
