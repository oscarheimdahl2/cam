#!/bin/bash
# Builds the signed Cam (development signing) and installs it to /Applications, then relaunches it.
#
#   scripts/install-local.sh            build and install
#   scripts/install-local.sh --icon     first pick up new icons from ~/Downloads: Cam.icon (the app icon, from Icon Composer)
#                                       and menuicon.png (the menu bar icon, white on transparent)
#
# The extension's build number is kept the same as the installed one, so macOS does not treat this as an
# extension update (an update would need approval again). Changing the extension itself needs a new number:
# run scripts/install-local.sh --new-extension, then use "Install / Update Virtual Camera" in the menu.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=""
for arg in "$@"; do
  case "$arg" in
    --icon)
      if [[ -d "$HOME/Downloads/Cam.icon" ]]; then
        if diff -rq "$HOME/Downloads/Cam.icon" App/Cam.icon >/dev/null 2>&1; then echo "App icon: unchanged"; else
          rm -rf App/Cam.icon; cp -R "$HOME/Downloads/Cam.icon" App/Cam.icon; echo "App icon: updated from Downloads"; fi
      else echo "App icon: no ~/Downloads/Cam.icon, keeping the current one"; fi
      if [[ -f "$HOME/Downloads/menuicon.png" ]]; then
        if cmp -s "$HOME/Downloads/menuicon.png" design/menuicon.png; then echo "Menu icon: unchanged"; else
          cp "$HOME/Downloads/menuicon.png" design/menuicon.png; echo "Menu icon: updated from Downloads"; fi
      else echo "Menu icon: no ~/Downloads/menuicon.png, keeping the current one"; fi
      swift scripts/make-menu-icon.swift ;;
    --new-extension) BUILD=$(date +%s) ;;
  esac
done

INSTALLED_EXT=/Applications/Cam.app/Contents/Library/SystemExtensions/com.oscarheimdahl.cam.extension.systemextension/Contents/Info.plist
if [[ -z "$BUILD" ]]; then
  BUILD=$(plutil -extract CFBundleVersion raw "$INSTALLED_EXT" 2>/dev/null || date +%s)
fi

xcodegen generate >/dev/null
xcodebuild -project Cam.xcodeproj -scheme Cam -configuration Debug \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CURRENT_PROJECT_VERSION="$BUILD" -quiet
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/Cam-*/Build/Products/Debug/Cam.app | head -1)
codesign --verify --deep --strict "$APP"

pkill -x Cam 2>/dev/null || true; pkill -x CamDev 2>/dev/null || true; sleep 1
rm -rf /Applications/Cam.app; cp -R "$APP" /Applications/Cam.app; touch /Applications/Cam.app
open /Applications/Cam.app
echo "Installed /Applications/Cam.app (extension build $BUILD)"
