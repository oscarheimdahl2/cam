# Cam

macOS menu-bar app (SwiftUI) that adds stickers, text and effects to the camera and outputs a virtual camera. See `README.md` for what it does and `project.yml` (XcodeGen) for targets. The `.xcodeproj` is generated, never edit it.

## After every code change

Rebuild and relaunch the dev app yourself so the user can see the change; don't leave that to them:

```
scripts/dev.sh
```

It regenerates the project, builds `CamDev`, quits the running copy, launches the new one, and the dev build opens the editor on its own. If the build fails it prints the error and leaves the running app alone: fix it and run again. Don't run it for changes that don't touch app code (docs, scripts).

- `CamDev` is the editor and live preview only, with no virtual camera. Changes to `Extension/` can't be seen this way; see `scripts/install-local.sh`.
- A copy of CamDev launched from Xcode can't be quit by the script. If two "DEV" items show in the menu bar, ask the user to stop the Xcode run (Cmd+.).

## Checks

- Unit tests: `xcodebuild -project Cam.xcodeproj -scheme CamTests test -quiet`
- Saved scenes must keep loading: when adding a field to a model type, decode it with `decodeIfPresent` and add a case to `Tests/PersistenceTests.swift`.
