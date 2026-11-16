# Plan 003: The self-updater verifies the download in Swift and never builds shell from network data

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c497768..HEAD -- Sources/Settings.swift`
> If it changed, compare the excerpts below against the live code; on a mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED (a broken updater strands users on old versions)
- **Depends on**: plans/001-build-the-working-tree.md (CoreParsers must be compiled and tested)
- **Category**: security
- **Planned at**: commit `c497768` + uncommitted WIP, 2026-11-17

## Why this matters

"Update Now" downloads a zip, then runs a `bash -c` script that **interpolates** the GitHub API's
`digest` string and the download's temp path into the script source, checks the hash only
`if [ -n "$EXPECT" ]`, deletes `/Applications/Sino.app` and moves the new one in. Three problems:
(1) network-derived text becomes shell code; (2) when the release asset has no digest — or when
`downloadURL` is nil and the hardcoded fallback URL is used — the update installs **unverified**;
(3) the script runs asynchronously after URLSession's completion handler returned, but URLSession
deletes the temp file when that handler returns, so the `cp` races the deletion. The fix: verify in
Swift with the already-written, unit-tested `UpdateValidator`, move the file before the handler returns,
refuse anything unverifiable, and pass the path to bash as an argument.

The live release already carries a digest (checked 2026-11-17: `v1.4.5` asset `Sino.app.zip` has
`digest: sha256:ca6354…a0cb`, matching `Formula/sino.rb`), so making it mandatory does not break updates.

## Current state

- `Sources/Settings.swift:726-739` — `final class Updater` with `@Published var downloadURL: URL?`,
  `@Published var downloadDigest: String?`, `isUpdating`, `updateProgress`, `status`; `static let repo = "Aduersarius/sino"`.
- `Sources/Settings.swift:783-788` — `check()` fills `downloadURL` from `browser_download_url` and
  `downloadDigest` from the asset's `digest` field.
- `Sources/Settings.swift:801-885` — `performUpdate()`. Key lines:
  ```swift
        guard let dl = downloadURL ?? URL(string: "https://github.com/\(Updater.repo)/releases/latest/download/Sino.app.zip") else {
  ...
            let expected = self.downloadDigest ?? ""
            let script = """
            set -e
            DEST="/Applications/Sino.app"
            WORK=$(mktemp -d /tmp/sino_update_XXXXXX)
            trap 'rm -rf "$WORK"' EXIT
            cp "\(tempURL.path)" "$WORK/Sino.app.zip"
            EXPECT="\(expected)"
            if [ -n "$EXPECT" ]; then
                GOT=$(shasum -a 256 "$WORK/Sino.app.zip" | cut -d' ' -f1)
                [ "sha256:$GOT" = "$EXPECT" ] || { echo "checksum mismatch: $GOT" >&2; exit 2; }
            fi
            ditto -x -k "$WORK/Sino.app.zip" "$WORK"
  ...
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments = ["-c", script]
  ```
  The rest of the script (extract, `cp -R` to `$DEST.new`, quit the running app via osascript, wait
  with `pgrep`, swap, `xattr -cr`, `open -n`) is correct and must be kept as is, including its comments.
- `Sources/CoreParsers.swift` `UpdateValidator.isTrustedGitHubURL(_:)`, `parseSHA256Digest(_:)`,
  `verifyFile(_:matchesDigest:)` — tested by `Tests/CoreParsersTests.swift` (plan 001).
- `openUpdate()` (`Settings.swift:899`) opens the release page in the browser — the safe fallback.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `swiftc -typecheck -parse-as-library -module-name Sino -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -import-objc-header Sources/Bridging.h Sources/*.swift` | exit 0 |
| Tests | `./tests.sh` | exit 0 |
| Release digest present | `curl -s https://api.github.com/repos/Aduersarius/sino/releases/latest \| python3 -c "import sys,json;print([a.get('digest') for a in json.load(sys.stdin)['assets']])"` | a `sha256:` value |

## Scope

**In scope**: `Sources/Settings.swift`, only `Updater.performUpdate()`.

**Out of scope**: `check()`, the notification code, the UI buttons, `Info.plist`, release tooling,
re-signing (the comment in the script explains why it must NOT re-sign — keep it).

## Git workflow

- Branch `advisor/003-updater-verify`; commit `fix(update): verify the download in Swift and refuse unverifiable updates`. Do not push.

## Steps

### Step 1: Refuse unverifiable updates up front
Replace the `guard let dl = downloadURL ?? URL(string: …) else { openUpdate(); return }` with:
```swift
        guard let dl = downloadURL,
              UpdateValidator.isTrustedGitHubURL(dl),
              UpdateValidator.parseSHA256Digest(downloadDigest) != nil else {
            openUpdate()  // nothing we can verify: let the user download from the release page
            return
        }
        let digest = downloadDigest  // read on main; the completion handler runs on a background queue
```
**Verify**: typecheck exit 0; `rg -n "releases/latest/download" Sources/Settings.swift` → no matches.

### Step 2: Move and verify the file inside the completion handler
At the top of the `downloadTask` completion handler, after the existing `err` / `tempURL` guards,
synchronously move the file and verify it **before the handler returns**:
```swift
            let zip = FileManager.default.temporaryDirectory
                .appendingPathComponent("sino-update-\(UUID().uuidString).zip")
            guard (try? FileManager.default.moveItem(at: tempURL, to: zip)) != nil,
                  UpdateValidator.verifyFile(zip, matchesDigest: digest) else {
                try? FileManager.default.removeItem(at: zip)
                DispatchQueue.main.async {
                    self.isUpdating = false
                    self.updateProgress = nil
                    self.status = "Update failed verification"
                }
                return
            }
```
**Verify**: typecheck exit 0.

### Step 3: Pass the path as an argument; drop the shell checksum
- Delete `let expected = …`, the `EXPECT=…` line and the whole `if [ -n "$EXPECT" ] … fi` block.
- Change `cp "\(tempURL.path)" "$WORK/Sino.app.zip"` to `cp "$1" "$WORK/Sino.app.zip"`.
- Change the trap to `trap 'rm -rf "$WORK"; rm -f "$1"' EXIT`.
- Change `proc.arguments = ["-c", script]` to `proc.arguments = ["-c", script, "sino-update", zip.path]`
  (with `bash -c`, the word after the script is `$0`, so the path is `$1`).
- The script literal must now contain **no** `\(` interpolation at all.

**Verify**:
- `rg -n 'EXPECT|tempURL\.path|\\\(expected\)' Sources/Settings.swift` → no matches
- `rg -n 'UpdateValidator\.(verifyFile|isTrustedGitHubURL|parseSHA256Digest)' Sources/Settings.swift` → 3 matches
- typecheck exit 0; `./tests.sh` exit 0

## Test plan

- Unit coverage for the validator already exists (plan 001). No new unit test: `performUpdate` is
  UI/process glue.
- Manual end-to-end (operator-approved, replaces the installed app): temporarily set
  `CFBundleShortVersionString` in `Info.plist` to `1.4.4`, `./build.sh`, open Settings → "Update Now";
  expect the app to relaunch as 1.4.5. Revert `Info.plist` before committing.

## Done criteria

- [ ] Typecheck and `./tests.sh` exit 0
- [ ] The three `rg` checks in Step 3 give the stated results
- [ ] `git diff --stat` shows only `Sources/Settings.swift` (+ `plans/README.md`)
- [ ] `plans/README.md` row updated

## STOP conditions

- The release-digest command prints `None` / no `sha256:` value (mandatory verification would block every update — report instead).
- `UpdateValidator` is missing or not compiled (plan 001 not done).
- The script body differs from the excerpt beyond the lines this plan changes.

## Maintenance notes

- Any future release must keep a `.zip` asset with a GitHub `digest`; GitHub computes it automatically
  for uploaded assets.
- The digest comes from the same API response as the URL, so this protects against corruption and
  injection, not against a compromised GitHub account. Real authenticity needs Developer ID signing +
  `codesign --verify` of the extracted app — deferred (needs a paid certificate).
