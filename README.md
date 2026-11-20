# Cam

A Mac menu-bar app that puts **stickers, text and effects** on your camera picture and sends the result to Teams, Zoom, Google Meet, Photo Booth and other apps as a **virtual camera**.

- **Layers:** drop in images (transparent PNGs work best), add text, or add a live particle effect (snow, fireflies, confetti, fireworks and more). Drag, resize and rotate them on a live preview.
- **Behind you or in front:** layers can sit behind you (using on-device person cut-out) or in front of you.
- **Follows your head:** tick *Follow head* and a layer moves, scales and tilts with your face, for hats and glasses.
- **Sticker look and party mode:** a white die-cut border with a soft shadow, and a slow rainbow tint and spin.
- **Scenes:** save different set-ups and switch between them from the menu bar, even mid-call.

Everything runs on your Mac. Cam's own code makes no network connections, and your scenes and stickers stay in `~/Library/Application Support/Cam`.

## Install

1. Download `Cam-0.1.dmg` from the [Releases page](../../releases) and open it.
2. Drag **Cam** into **Applications**, then open it from there, *not* from the disk image or Downloads. (macOS only installs the virtual camera for an app that lives in `/Applications`. If you skip this, Cam tells you to move it.)
3. Click the Cam icon in the menu bar and choose **Install / Update Virtual Camera**.
4. macOS will say a system extension was blocked. Open **System Settings → General → Login Items & Extensions → Camera Extensions** and switch **Cam** on.
5. Cam offers to restart itself once, so it can connect to the new camera. Accept.
6. In your meeting app, choose **Cam** as the camera. Quit and reopen the app first if Cam isn't listed.

Cam has to be running for the picture to show. Without it, the camera shows a card saying "Cam isn't running". Turn on **Launch at Login** in the menu to avoid that. If you see that card while Cam is open, quit Cam from its menu and open it again.

**Background blur:** Cam doesn't blur your background itself. Use macOS's own Portrait effect (Control Center → Video Effects) while Cam is running, and it comes through Cam together with your stickers.

## Uninstall

Choose **Uninstall Virtual Camera…** from the menu bar icon, then drag Cam out of Applications. Your scenes and stickers are in `~/Library/Application Support/Cam`; delete that folder too if you want them gone.

## Requirements and status

- macOS 14 or later (developed and tested on macOS 27, Apple Silicon). The download is a universal build, but Intel Macs and macOS 14 to 26 have not been tested.
- Confirmed working in **Photo Booth**. Other apps that list cameras (Teams, Zoom, Meet) should work the same way, but have not all been tested. Reports are welcome as issues.
- This is an early release (0.1). Expect rough edges.
- Some organisations block system extensions on managed Macs. If yours does, the virtual camera can't be installed.

## Check your download

The app and the DMG are signed with a Developer ID and notarized by Apple. After downloading, you can check that yourself:

```
shasum -a 256 Cam-0.1.dmg                       # compare with the checksum in the release notes
spctl --assess --type open --context context:primary-signature -v Cam-0.1.dmg
codesign -dvv /Applications/Cam.app             # shows who signed it
```

## Build from source

You need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and, for the virtual camera, a paid Apple Developer account (a free account cannot install system extensions).

```
xcodegen generate                  # creates Cam.xcodeproj from project.yml
open Cam.xcodeproj
```

Change `TEAM_ID` in `project.yml` to your own team first. The `CamDev` scheme builds the editor and live preview without the virtual camera and works with a free account. Handy scripts are in `scripts/`:

| Script | What it does |
|---|---|
| `scripts/install-local.sh` | Build the signed `Cam` and install it to `/Applications` for development |
| `scripts/release.sh` | Release build, Developer ID signing, notarization, stapling and a DMG |
| `scripts/check-no-user-data.sh` | Fails if scenes or stickers ended up inside an app bundle |

Run the unit tests with `xcodebuild test -project Cam.xcodeproj -scheme CamTests -destination 'platform=macOS'`.

## License

[MIT](LICENSE). Particle effects use [Vortex](https://github.com/twostraws/Vortex) by Paul Hudson, also MIT; its notice is in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) and in the app's About window.
