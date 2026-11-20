#!/bin/bash
# Builds a distributable Cam: Release build, Developer ID signing, notarization, stapling and a DMG.
#
#   scripts/release.sh                 full release (needs the notarization profile, see below)
#   scripts/release.sh --skip-notarize build, sign and package only (to test the packaging; Gatekeeper will still warn)
#   BUILD_NUMBER=1795168971 scripts/release.sh   pin the build number (the extension version) instead of using the clock
#
# One-time setup, in your own Terminal (so the password never ends up in a chat or a log):
#   xcrun notarytool store-credentials "cam-notary" --apple-id "<your apple id>" --team-id "<your team id>"
# It asks for an app-specific password (account.apple.com > Sign-In and Security > App-Specific Passwords).
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="cam-notary"
SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

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
xcodebuild archive -project Cam.xcodeproj -scheme Cam -configuration Release \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CURRENT_PROJECT_VERSION="$BUILD" -quiet

echo "== 3/6 Export signed with Developer ID"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$EXPORT" -allowProvisioningUpdates -quiet
APP="$EXPORT/Cam.app"
codesign --verify --deep --strict "$APP"
"$(dirname "$0")/check-no-user-data.sh" "$APP"   # a fresh install must start empty

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  echo "== 4/6 Notarize the app (Apple scans it; usually a few minutes)"
  ditto -c -k --keepParent "$APP" "$OUT/Cam-notarize.zip"
  xcrun notarytool submit "$OUT/Cam-notarize.zip" --keychain-profile "$PROFILE" --wait
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
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
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
