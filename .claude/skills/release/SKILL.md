---
name: release
description: Publish a new Cam release with the minor version bumped (0.2 -> 0.3). Commits the pending changes, tags, and lets the GitHub release workflow build, notarize and publish the DMG.
disable-model-invocation: true
---

# Release Cam

Cuts a release with the minor version bumped. The version lives in `MARKETING_VERSION` in `project.yml` ("0.2");
the tag is that plus `.0` ("v0.2.0"). Pushing the tag runs `.github/workflows/release.yml`, which builds, signs,
notarizes and publishes the DMG. This is outward-facing and can't be undone cleanly, so confirm before the push.

## Steps

1. **Pre-flight.** Be on `main` and in sync with `origin/main` (`git fetch`, then compare). Work out the new version:
   read the current `MARKETING_VERSION` (`X.Y`), the new one is `X.(Y+1)`, the tag `vX.(Y+1).0`. Stop if that tag
   already exists. Run `git status` and `git log <last tag>..HEAD --oneline`.
2. **Tests.** `xcodebuild -project Cam.xcodeproj -scheme CamTests test -quiet`. Stop and report if they fail.
3. **Release notes.** Write a short, user-facing summary of what changed since the last tag, from the commits and the
   uncommitted diff (features and fixes people will notice, not file names).
4. **Confirm.** Show the user the new version, the files that will be committed and the notes. Wait for a yes.
5. **Bump and commit.**
   - Set `MARKETING_VERSION` in `project.yml` to the new `X.Y`.
   - Update the version in `README.md` (the `Cam-X.Y.dmg` name and the "early release (X.Y)" line).
   - Commit all pending changes plus the bump in one commit: `Release X.Y: <one-line summary>`. Never commit secrets
     or `.env` files; warn if any are among the changes.
   - Push `main`.
6. **Tag.** `git tag vX.Y.0 && git push origin vX.Y.0`.
7. **Watch.** `gh run list --workflow release.yml --limit 1`, then `gh run watch <id> --exit-status`. It takes about
   2-3 minutes. If it fails, read `gh run view <id> --log-failed`, report the cause, and stop; don't delete or
   re-push the tag without asking.
8. **Notes and verify.** Replace the release body with the notes from step 3 (keep the SHA-256 line):
   `gh release edit vX.Y.0 --notes-file <file>`. Download the DMG (`gh release download`) and check it:
   `xcrun stapler validate`, `spctl --assess --type open --context context:primary-signature -v`, and that the
   app inside has `Contents/Resources/Cam.icns`.
9. **Report.** The release URL, the version, the checksum and anything that looked off.

## Notes

- The workflow marks `v0.*` releases as pre-releases. That's intended until 1.0.
- If the Extension code changed, mention in the notes that users must click "Install / Update Virtual Camera" and
  restart apps that use the camera (see the comment at the top of `scripts/install-local.sh`).
- Dry run without publishing: Actions → Release → Run workflow (needs admin rights; `gh` here usually lacks them).
