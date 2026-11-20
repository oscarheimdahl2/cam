#!/bin/bash
# Rebuilds the CamDev app and relaunches it with the editor open. No Xcode needed.
#
#   scripts/dev.sh           build, quit the running CamDev, launch the new one
#   scripts/dev.sh --watch   do that again every time a source file changes (needs: brew install fswatch)
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=build/dev
APP="$DERIVED/Build/Products/Debug/CamDev.app"

run_once() {
  xcodegen generate >/dev/null
  if ! xcodebuild -project Cam.xcodeproj -scheme CamDev -configuration Debug -derivedDataPath "$DERIVED" build -quiet; then
    echo "Build failed; leaving the running CamDev alone." >&2
    return 1
  fi
  # Quit politely; a copy that Xcode launched sits under its debugger and ignores that, so force it after a moment.
  if pkill -x CamDev 2>/dev/null; then
    for _ in 1 2 3 4 5; do pgrep -x CamDev >/dev/null || break; sleep 0.2; done
    pkill -9 -x CamDev 2>/dev/null || true
  fi
  open "$APP"
  echo "CamDev relaunched."
}

if [[ "${1:-}" == "--watch" ]]; then
  command -v fswatch >/dev/null || { echo "Install fswatch first: brew install fswatch" >&2; exit 1; }
  run_once || true
  # -o batches a burst of saves into one event; -l waits for it to settle.
  fswatch -o -l 1 App Shared project.yml | while read -r _; do run_once || true; done
else
  run_once
fi
