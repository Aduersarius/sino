# Plan 001: build.sh builds the current tree, and CoreParsers has tests

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c497768..HEAD -- build.sh tests.sh Sources/CoreParsers.swift Sources/smcwrite.c Tests/`
> The only expected change is the commit that landed the owner's WIP (see README "Plan 000").
> If anything else changed in these paths, compare the "Current state" excerpts against the
> live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: Plan 000 (owner commits the WIP — see `plans/README.md`)
- **Category**: dx
- **Planned at**: commit `c497768` + uncommitted WIP, 2026-11-17

## Why this matters

`./build.sh` is the only real build (the Makefile is stale). In the current tree it is broken twice:
the privileged helper `Sources/smcwrite.c` now calls Security.framework (`SecCodeCopySelf`, …) but
build.sh links it without `-framework Security`, so the link fails and `set -e` aborts the whole build;
and the new `Sources/CoreParsers.swift` (pure, testable helpers that later plans rely on:
`CPUCoreLayout`, `UpdateValidator`) is not in build.sh's source list, so it is never compiled into the
app. This plan makes the build green and gives CoreParsers a test binary, which plans 002, 003 and 006
depend on.

## Current state

- `build.sh` — builds the helper, then the app, then installs into `/Applications/Sino.app`.
  Line 15–17 (helper link, missing Security):
  ```bash
  cc -O2 -o /tmp/sino-smcwrite "$ROOT/Sources/smcwrite.c" \
    -isysroot "$SDK" -target arm64-apple-macos14.0 \
    -framework IOKit -framework CoreFoundation
  ```
  Line ~23 (app compile) ends with an explicit file list:
  `... "/tmp/sino_build/Sources/SkyLightProbe.swift" "/tmp/sino_build/Sources/BlurFold.swift"` —
  `CoreParsers.swift` is absent.
- Reproduction of the link failure (verified 2026-11-17):
  `cc -O2 -o /tmp/x Sources/smcwrite.c -isysroot "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 -framework IOKit -framework CoreFoundation`
  → `Undefined symbols for architecture arm64: "_SecCodeCheckValidity" …`
- `tests.sh` — the whole test runner:
  ```bash
  #!/bin/bash
  # Runs the FoldCore assertions. No Xcode, no XCTest: swiftc + the sources.
  set -euo pipefail
  ROOT="$(cd "$(dirname "$0")" && pwd)"
  mkdir -p /tmp/sino_tests
  swiftc -O "$ROOT/Sources/FoldCore.swift" "$ROOT/Tests/FoldCoreTests.swift" -o /tmp/sino_tests/foldcore
  /tmp/sino_tests/foldcore
  ```
- Test convention (exemplar: `Tests/FoldCoreTests.swift`): no XCTest. A `@main struct` with a local
  `check(_ ok: Bool, _ what: String)` that counts failures and prints `FAIL <what>`, then prints a
  one-line summary and `exit(failures == 0 ? 0 : 1)`. Match it exactly.
- `Sources/CoreParsers.swift` `UpdateValidator` (lines ~281–323): `allowedHosts`,
  `isTrustedGitHubURL(_:)` (https only; allowed host set or `*.githubusercontent.com`),
  `parseSHA256Digest(_:)` (accepts optional `sha256:` prefix, 64 hex chars, lowercases),
  `sha256Hex(fileAt:)`, `verifyFile(_:matchesDigest:)`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Swift typecheck (no artifacts) | `swiftc -typecheck -parse-as-library -module-name Sino -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -import-objc-header Sources/Bridging.h Sources/*.swift` | exit 0, no output |
| Helper link check (writes only /tmp) | `cc -O2 -o /tmp/sino-smcwrite-check Sources/smcwrite.c -isysroot "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 -framework IOKit -framework CoreFoundation -framework Security` | exit 0 |
| Tests | `./tests.sh` | ends with `core parsers: all checks passed`, exit 0 |
| Full build | `./build.sh` | `built and installed to /Applications/Sino.app` — **replaces the installed app; run only if the operator allows** |

## Scope

**In scope**: `build.sh`, `tests.sh`, `Tests/CoreParsersTests.swift` (create).

**Out of scope**:
- `Makefile` — stale, separate decision; do not "fix" it.
- Any Swift source change. In particular do not delete the duplicate parsers that still live in
  `Sources/Sampler.swift` (`canonicalAppName`, the ipinfo decoder) — that cleanup is a separate decision.
- `Sources/smcwrite.c` / `Sources/SMC.c` behavior (plan 006 owns them).

## Git workflow

- Branch: `advisor/001-build-the-working-tree`
- Conventional commits, matching `git log` (e.g. `fix(formula): v1.4.5 asset and checksum`).
  Suggested: `fix(build): link the helper against Security and compile CoreParsers`, `test(parsers): cover UpdateValidator`.
- Do NOT push.

## Steps

### Step 1: Link the helper against Security.framework
In `build.sh`, append `-framework Security` to the `cc` line that builds `/tmp/sino-smcwrite`.

**Verify**: `rg -n "framework Security" build.sh` → exactly one match on the `cc` line; the "Helper link check" command → exit 0.

### Step 2: Compile CoreParsers.swift into the app
In `build.sh`, add `"/tmp/sino_build/Sources/CoreParsers.swift"` to the swiftc file list (anywhere in the list; put it after `Sampler.swift`).

**Verify**: `rg -c "Sources/CoreParsers.swift" build.sh` → `1`; Swift typecheck → exit 0.

### Step 3: Add the CoreParsers test binary
Create `Tests/CoreParsersTests.swift` in the FoldCoreTests style (`import Foundation`, `@main struct CoreParsersTests { static func main() { … } }`, local `check`, summary line `core parsers: all checks passed` / `core parsers: N failure(s)`, `exit`). Cover `UpdateValidator`:
- `parseSHA256Digest("sha256:" + 64 lowercase hex)` → the 64 hex chars
- uppercase hex input → lowercased result
- 63 chars → nil; 64 chars containing `g` → nil; `nil` → nil; `"  sha256:<hex>\n"` (whitespace) → hex
- `isTrustedGitHubURL`: `https://github.com/a/b` true; `http://github.com/a/b` false; `https://evil.com` false;
  `https://github.com.evil.com/x` false; `https://objects.githubusercontent.com/x` true;
  `https://evilgithubusercontent.com/x` false
- `verifyFile`: write `"abc"` to a file in `FileManager.default.temporaryDirectory`; digest
  `sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad` → true; same digest with
  last char changed → false; `nil` digest → false. Delete the file afterwards.

Append to `tests.sh` (after the foldcore lines):
```bash
swiftc -O "$ROOT/Sources/CoreParsers.swift" "$ROOT/Tests/CoreParsersTests.swift" -o /tmp/sino_tests/coreparsers
/tmp/sino_tests/coreparsers
```

**Verify**: `./tests.sh` → prints `fold core: all checks passed` then `core parsers: all checks passed`, exit 0.
Then temporarily change one expected value in the new test, rerun → exit 1 with a `FAIL` line; revert.

## Test plan

- New: `Tests/CoreParsersTests.swift`, ≥ 13 checks listed in Step 3, modeled on `Tests/FoldCoreTests.swift`.
- Verification: `./tests.sh` → exit 0.

## Done criteria

- [ ] Helper link check exits 0
- [ ] Swift typecheck exits 0
- [ ] `./tests.sh` exits 0 and prints `core parsers: all checks passed`
- [ ] `git status --short` shows only `build.sh`, `tests.sh`, `Tests/CoreParsersTests.swift` (and `plans/README.md`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `git ls-files --error-unmatch Sources/CoreParsers.swift` fails (the WIP was not committed — Plan 000 not done).
- Swift typecheck reports duplicate symbols between `CoreParsers.swift` and another file.
- The helper still fails to link with `-framework Security` (report the undefined symbols).

## Maintenance notes

- Every new Swift file must be added to build.sh's explicit list; the typecheck command uses
  `Sources/*.swift`, so it will NOT catch an omission. A reviewer should check the list.
- Plan 006 adds `-lbsm` to the same `cc` line.
