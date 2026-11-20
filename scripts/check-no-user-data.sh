#!/bin/bash
# Fails if an app bundle contains anything that looks like personal Cam data (scenes or stickers).
# A fresh install must start empty: scenes and sticker images live in the user's own folder
# (~/Library/Application Support/Cam), never inside the app. Used by scripts/release.sh.
#
#   scripts/check-no-user-data.sh path/to/Cam.app
set -euo pipefail
APP="${1:?usage: check-no-user-data.sh path/to/Cam.app}"
[[ -d "$APP" ]] || { echo "Not an app bundle: $APP" >&2; exit 2; }

FOUND=$(find "$APP" \( -name "config.json" -o -name "stickers" -o -name "*.camscene" \) -print)
# Any loose image in Resources apart from the icon and the Vortex library's own assets would also be suspicious.
LOOSE=$(find "$APP/Contents/Resources" -maxdepth 1 \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.heic" \) -print 2>/dev/null || true)

if [[ -n "$FOUND$LOOSE" ]]; then
  echo "Personal data found inside the app, refusing to continue:" >&2
  echo "$FOUND$LOOSE" | sed 's/^/  /' >&2
  exit 1
fi
echo "OK: no scenes or sticker images inside $(basename "$APP")"
