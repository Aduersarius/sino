# Plan 007: Sino's system changes are user-scoped, never prompt on launch/quit, and can be removed

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c497768..HEAD -- Sources/SinoApp.swift Sources/Settings.swift Sources/smcwrite.c`
> Plan 006 is expected to have touched `smcwrite.c` and `SinoApp.swift:setFanMode`. Anything touching
> `PMSetHelper`, `FanCtl`, `OnboardingState` or the Awake settings: compare excerpts; on mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (touches sudoers and the lid-sleep path; a mistake can leave `disablesleep` on)
- **Depends on**: plans/006-fan-helper-auth.md (both edit `smcwrite.c`)
- **Category**: security
- **Planned at**: commit `c497768` + uncommitted WIP, 2026-11-17

## Why this matters

Sino makes two persistent system changes and offers no way to undo either:
1. `/etc/sudoers.d/sino_awake` grants **every admin account** passwordless
   `pmset -a disablesleep 0|1` and `pmset -a lowpowermode 0|1` (`%admin ALL=(ALL) NOPASSWD: SINO_PMSET`).
   Any process running as any admin user can then silently stop the Mac from sleeping with the lid closed.
2. A root LaunchDaemon `com.lov3u.sino.smcwrite` (`KeepAlive`) for fan control.

Deleting the app leaves both behind. Separately, `PMSetHelper.setPmset` falls back to an **admin password
prompt** whenever `sudo -n` fails. The app calls `setSleepDisabled(false)` unconditionally at launch
(`SinoApp.swift:216-217`) and `setSleepDisabledNow(false)` at quit (`SinoApp.swift:196-199` → `:764`),
so a user who never installed the rule is (by code reading) asked for an admin password on launch and on
quit just to reset a value that is already 0.

## Current state

- `Sources/SinoApp.swift:4897-4899`:
  ```swift
  enum PMSetHelper {
      static let sudoersFile = "/private/etc/sudoers.d/sino_awake"
      static let sudoersBody = "Cmnd_Alias SINO_PMSET = /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a lowpowermode 1, /usr/bin/pmset -a lowpowermode 0\n%admin ALL=(ALL) NOPASSWD: SINO_PMSET\n"
  ```
- `:4901-4910` — `isSudoersInstalled` = file exists; `installSudoers()` runs
  `printf '%s' '<body>' > <file> && chmod 0440 <file>` through `runPrivileged`.
- `:4912` `isSleepDisabled` → `pmsetFlag("SleepDisabled")` (reads `pmset -g`, no root needed).
- `:4939-4957` — `pmsetQueue` (serial); `setSleepDisabled(_:completion:)` async, `setSleepDisabledNow(_:)` sync.
- `:4963-4980` — `setPmset(key, on)`: test hook `SINO_PMSET_FAIL`; `sudo -n /usr/bin/pmset -a key val`;
  on failure **re-writes the sudoers file and runs pmset via `runPrivileged` (admin prompt)**.
- `:4982-4996` — `runPrivileged(command)`: `osascript -e 'do shell script "…" with administrator privileges'`.
- `Sources/SinoApp.swift:4871-4895` — `enum FanCtl { ready; install() }` (osascript `"<helper>" --install`).
- `Sources/smcwrite.c:376-421` — `do_install(self)`; `main` dispatches `--install` (`if (argc >= 2 && strcmp(argv[1], "--install") == 0)`).
  Paths: `DEST`, `PLIST`, `SOCK`, `LABEL` (`smcwrite.c:24-27`).
- `Sources/Settings.swift:3026-3048` — `OnboardingState` (`sudoersInstalled`, `configureClamshell`).
  Settings toggle for lid-close prevention: `Settings.swift:1244-1245`
  (`get: { prefs.preventLidSleep }, set: { app.setPreventLidSleep($0) }`).
- `Sources/CoreParsers.swift` `PMSetParser.isValidPosixUsername(_:)` — already written for safely putting a user name into sudoers.
- Installed state on the owner's Mac: `/etc/sudoers.d/sino_awake` (root:wheel 0440, Sep 17).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Swift typecheck | `swiftc -typecheck -parse-as-library -module-name Sino -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -import-objc-header Sources/Bridging.h Sources/*.swift` | exit 0 |
| Helper compile | `cc -Wall -Wextra -O2 -o /tmp/sino-smcwrite-check Sources/smcwrite.c -isysroot "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 -framework IOKit -framework CoreFoundation -framework Security -lbsm` | exit 0, no warnings |
| Tests | `./tests.sh` | exit 0 |
| Sudoers syntax of the new body | `printf '%s' "<body>" > /tmp/sino_v2 && /usr/sbin/visudo -cf /tmp/sino_v2` | `/tmp/sino_v2: parsed OK` |
| Full build | `./build.sh` | **operator approval required** |

## Scope

**In scope**: `Sources/SinoApp.swift` (`PMSetHelper`, `FanCtl`, plus one new `removeSystemHelpers()` on the app object), `Sources/Settings.swift` (one button + caption near line 1244, and the onboarding caption text that names the file), `Sources/smcwrite.c` (`--uninstall`).

**Out of scope**: the Awake session logic in `startAwake`/`stopAwake` (heavily debugged, see `git log --oneline -- Sources/SinoApp.swift`); `LidFold.swift`; the launch-time and quit-time reset calls themselves (keep them — Step 1 makes them cheap).

## Git workflow

- Branch `advisor/007-uninstall-and-scope`; commits e.g. `fix(sleep): skip pmset writes that change nothing`,
  `fix(sleep): scope the pmset rule to the current user`, `feat(settings): remove Sino's system helpers`. Do not push.

## Steps

### Step 1: Don't write (or prompt) when the value is already right
At the top of `setPmset`, after the `SINO_PMSET_FAIL` hook:
```swift
        let flag = key == "disablesleep" ? "SleepDisabled" : key
        if pmsetFlag(flag) == on { return true }  // already in the wanted state: no sudo, no prompt
```
`setSleepDisabled`/`setSleepDisabledNow` run `setPmset` on the serial `pmsetQueue`, so this read happens
after any queued write — it does not reintroduce the race the comments at `SinoApp.swift:758-762` describe.
**Verify**: typecheck → exit 0. With `pmset -g | rg SleepDisabled` showing `0`, launching and quitting a
build without the sudoers rule shows no admin prompt (manual, operator-approved).

### Step 2: User-scoped, syntax-checked sudoers rule (v2), replacing the legacy file
- Add `static let legacySudoersFile = "/private/etc/sudoers.d/sino_awake"` and change
  `sudoersFile` to `"/private/etc/sudoers.d/sino_awake_v2"`.
- Make the body a computed `static var sudoersBody: String?` that returns `nil` unless
  `PMSetParser.isValidPosixUsername(NSUserName())`, and otherwise the same `Cmnd_Alias` line followed by
  `"\(NSUserName()) ALL=(root) NOPASSWD: SINO_PMSET\n"`.
- Add one helper that builds the install command and use it in both `installSudoers()` and the
  `setPmset` fallback (`:4979`), so the body is never spelled twice:
  ```
  printf '%s' '<body>' > /private/etc/sudoers.d/.sino_awake_v2.tmp
  && /usr/sbin/visudo -cf /private/etc/sudoers.d/.sino_awake_v2.tmp
  && chmod 0440 /private/etc/sudoers.d/.sino_awake_v2.tmp
  && mv /private/etc/sudoers.d/.sino_awake_v2.tmp /private/etc/sudoers.d/sino_awake_v2
  && rm -f /private/etc/sudoers.d/sino_awake
  ```
  (sudo ignores files in `sudoers.d` whose name contains a `.`, so the temp file is inert; `visudo -c`
  prevents a broken file from locking the user out of `sudo`). If `sudoersBody` is nil, return `false` without prompting.
- Update the onboarding caption at `Settings.swift:3158` to name `/etc/sudoers.d/sino_awake_v2` and say it
  applies to the current user only.
**Verify**: typecheck → exit 0; the visudo command on the generated body (substitute your user name) → `parsed OK`;
`rg -n "%admin" Sources` → no matches.

### Step 3: `--uninstall` in the helper
In `smcwrite.c`, add `static int do_uninstall(void)`: require `geteuid() == 0`; run
`/bin/launchctl bootout system/` LABEL (the daemon's SIGTERM handler resets fans to auto); `unlink(PLIST)`,
`unlink(DEST)`, `unlink(SOCK)`; return 0. Dispatch it in `main` next to `--install`.
**Verify**: helper compile → exit 0, no warnings; `rg -n '"--uninstall"' Sources/smcwrite.c` → 1 match.

### Step 4: One "remove everything" action
- Make `PMSetHelper.runPrivileged` non-private.
- Add to the app object (same type that has `releaseFans()` and `stopAwake(...)`) a `func removeSystemHelpers()`
  that: calls `stopAwake(reason: "remove helpers")` and `releaseFans()`; then on a background queue runs
  **one** `runPrivileged` with
  `/usr/bin/pmset -a disablesleep 0; rm -f /private/etc/sudoers.d/sino_awake_v2 /private/etc/sudoers.d/sino_awake; "<bundled helper path>" --uninstall`
  where the bundled helper path is resolved exactly as `FanCtl.install()` does (`Bundle.main.path(forResource: "sino-smcwrite", ofType: nil)`)
  and escaped the same way. Use the **bundled** helper, not `/Library/PrivilegedHelperTools/…` — an old
  installed helper doesn't know `--uninstall` and would start a second daemon.
- `Settings.swift`, right below the lid-close toggle (`~1244`): a `Button("Remove system helpers…")` calling
  it, with a caption: "Removes the pmset rule and the fan-control helper. Lid-close prevention and fan control stop working until you turn them on again."
**Verify**: typecheck → exit 0; `./tests.sh` → exit 0.

### Step 5 (operator-approved): live check
`./build.sh`; Settings → "Remove system helpers…" → one admin prompt. Then:
- `ls /etc/sudoers.d/ | rg sino` → nothing
- `ls /Library/LaunchDaemons/com.lov3u.sino.smcwrite.plist /Library/PrivilegedHelperTools/com.lov3u.sino.smcwrite 2>&1 | rg -c "No such file"` → `2`
- `launchctl print system/com.lov3u.sino.smcwrite >/dev/null 2>&1; echo $?` → non-zero
- `pmset -g | rg SleepDisabled` → `0` (or no line)
Then re-enable lid-close prevention (one prompt) → `sudo -n /usr/bin/pmset -a disablesleep 0; echo $?` → `0`,
and `sudo cat /etc/sudoers.d/sino_awake_v2` shows your user name, not `%admin`.

## Test plan

- `PMSetParser.isValidPosixUsername` is pure: add to `Tests/CoreParsersTests.swift` (from plan 001): `"lov3u"` true, `"a b"` false, `"x;rm"` false, `""` false, 65 chars false.
- Everything else is privileged glue: Step 5 is the behavioral check.

## Done criteria

- [ ] Typecheck, helper compile, `./tests.sh` all exit 0
- [ ] `rg -n "%admin" Sources` → no matches
- [ ] `rg -n "visudo -cf" Sources/SinoApp.swift` → 1 match (single install-command builder)
- [ ] `git diff --stat` touches only in-scope files (+ `plans/README.md`)
- [ ] Step 5 results as stated, if the operator allowed it
- [ ] `plans/README.md` row updated

## STOP conditions

- `pmset -g` on the executor's machine has no `SleepDisabled` line even while prevention is on (Step 1's check would then be wrong).
- `visudo -cf` rejects the generated body.
- Removing the helpers leaves `SleepDisabled 1` (Step 5) — report immediately; that is the dangerous state.

## Maintenance notes

- Users upgrading keep the legacy `%admin` file until they press Configure, toggle the feature on again, or
  use "Remove system helpers…". A follow-up could detect `legacySudoersFile` and offer the upgrade once.
- If a new pmset key is ever needed, add it to `Cmnd_Alias` in the single body builder.
