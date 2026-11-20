#!/bin/bash
# Builds the signed Cam (development signing), installs it to /Applications and relaunches it.
#
#   scripts/install-local.sh                  build and install (it quits a running Cam first)
#   scripts/install-local.sh --check          only report whether the extension changed since the last install; build nothing
#   scripts/install-local.sh --icon           first pick up new icons from ~/Downloads (Cam.icon and menuicon.png)
#   scripts/install-local.sh --new-extension  force a new extension version even if its code didn't change
#
# THE APP AND THE EXTENSION ARE SEPARATE PROGRAMS. The app (everything outside Extension/) is replaced every time
# you run this, and needs nothing else. The extension (the virtual camera that Photo Booth and Teams talk to) is
# installed in the system by macOS and only changes when you ask it to. It is built from Extension/ and
# Shared/SharedConstants.swift, so this script fingerprints those files:
#   - unchanged: it reuses the installed extension's version number, so macOS sees no extension update. Nothing to do.
#   - changed:   it gives the extension a new, higher version. Afterwards, click "Install / Update Virtual Camera" in
#                the menu, approve if asked, accept the restart, and restart Photo Booth / Teams.
set -euo pipefail
cd "$(dirname "$0")/.."

STATE=build/extension-sources.sha256   # fingerprint of the extension code the last install was built from
mkdir -p build

extension_fingerprint() {
  find Extension Shared/SharedConstants.swift -type f ! -name '.DS_Store' | LC_ALL=C sort | xargs cat | shasum -a 256 | awk '{print $1}'
}
# The build number of the extension macOS is actually running right now (empty if none).
active_extension_build() {
  systemextensionsctl list 2>/dev/null | grep 'activated enabled' | grep com.oscarheimdahl.cam.extension \
    | sed -E 's/.*\(([^)]*)\).*/\1/' | sed 's#.*/##' | head -1
}
BUNDLED_EXT=/Applications/Cam.app/Contents/Library/SystemExtensions/com.oscarheimdahl.cam.extension.systemextension/Contents/Info.plist
NOW=$(extension_fingerprint)
SAVED=$(cat "$STATE" 2>/dev/null || true)

FORCE=0; CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --new-extension) FORCE=1 ;;
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
  esac
done

if [[ -z "$SAVED" ]]; then
  # First run with this script: treat what is installed as the baseline.
  echo "$NOW" > "$STATE"; SAVED="$NOW"; echo "Extension: no earlier record, taking the current code as the installed one"
fi
if [[ $FORCE -eq 1 || "$SAVED" != "$NOW" ]]; then CHANGED=1; else CHANGED=0; fi

if [[ $CHECK -eq 1 ]]; then
  ACTIVE=$(active_extension_build); IN_APP=$(plutil -extract CFBundleVersion raw "$BUNDLED_EXT" 2>/dev/null || true)
  if [[ $CHANGED -eq 1 ]]; then echo "Extension code: CHANGED since the last install. Running install-local.sh will bump its version."
  else echo "Extension code: unchanged. Installing only replaces the app."; fi
  echo "Extension version running now: ${ACTIVE:-none}; version inside /Applications/Cam.app: ${IN_APP:-none}"
  if [[ -n "$IN_APP" && "$ACTIVE" != "$IN_APP" ]]; then echo ">> They differ: click \"Install / Update Virtual Camera\" in the Cam menu to switch."; fi
  exit 0
fi

INSTALLED_EXT=/Applications/Cam.app/Contents/Library/SystemExtensions/com.oscarheimdahl.cam.extension.systemextension/Contents/Info.plist
if [[ $CHANGED -eq 1 ]]; then
  BUILD=$(date +%s)
else
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
echo "$NOW" > "$STATE"   # only after a successful build and install
echo
echo "Installed /Applications/Cam.app"
ACTIVE=$(active_extension_build)
if [[ "$ACTIVE" != "$BUILD" ]]; then
  # What matters is the version macOS is running, not whether the code changed this time: a build can be
  # installed without ever being switched on.
  echo "EXTENSION NOT UP TO DATE: macOS is running version ${ACTIVE:-none}, this app contains version $BUILD. To switch:"
  echo "  1. Cam menu > Install / Update Virtual Camera (approve in System Settings if asked, accept the restart)"
  echo "  2. Quit and reopen Photo Booth / Teams"
else
  echo "Extension up to date (version $BUILD): nothing to reinstall."
fi
