# Plan 012: Remove the fake Clean RAM feature

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, leave `plans/README.md` to your reviewer.
>
> **Drift check (run first)**: `git diff --stat 540918b..HEAD -- Sources/Sampler.swift Sources/SinoApp.swift`
> Plans 010 and 011 may have edited other sections of these files. Compare the `cleanRAM`/`cleaningRAM`/`cleanFeedback`
> regions against the excerpts below; on mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/010-fan-socket-off-main.md, plans/011-procs-rusage-and-off-main.md (same files)
- **Category**: bug
- **Planned at**: commit `540918b`, 2026-11-17

## Why this matters

`cleanRAM()` allocates and writes up to 3 GiB of anonymous pages, sleeps 80 ms, calls `vm_deallocate`, and
reports `free_after - free_before` as "Freed X GB". Most of the reported "freed" bytes are the pages the app
itself just allocated and released, while the temporary 512 MB–3 GB allocation pushes other apps' active memory
into compression and swap. Removing it deletes ~110 lines of misleading, counterproductive code and leaves
the Memory card honest.

## Current state

- `Sources/Sampler.swift:340-396`: `private var cleaningRAM = false` and `func cleanRAM(completion: ((Int64) -> Void)? = nil)`.
- `Sources/SinoApp.swift:39-40`: `@Published var cleaningRAM = false`, `@Published var cleanFeedback: String? = nil`.
- `Sources/SinoApp.swift:917-938`: `func cleanRAM()` (dead duplicate of the inline closure in the UI!).
- `Sources/SinoApp.swift:2968-3044`: `Card("MEMORY", "memorychip", pal) { ... } headerTrailing: { ... }` (contains the `app.cleanFeedback` badge and `"Clean"` button). `Card` has a default initializer without `headerTrailing:` (used right below at line 3046: `Card("PROCESSES", ...)`).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Swift typecheck | `swiftc -typecheck -parse-as-library -module-name Sino -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -import-objc-header Sources/Bridging.h Sources/*.swift` | exit 0 |
| Tests | `./tests.sh` | exit 0 |
| Dead symbol check | `rg -n "cleanRAM\|cleaningRAM\|cleanFeedback\|Quick RAM Clean" Sources` | no matches (exit 1) |

## Scope

**In scope**: `Sources/Sampler.swift` (`cleaningRAM`, `cleanRAM`), `Sources/SinoApp.swift` (`cleaningRAM`, `cleanFeedback`, `cleanRAM`, `ramSection` `headerTrailing`).

**Out of scope**: all other Memory card rows (`Used`, `Wired`, `Compressed`, `Free`, `Swap`).

## Git workflow

- Branch `advisor/012-remove-clean-ram`; commit `refactor(ram): remove fake cleanRAM memory-pressure trick`. Do not push.

## Steps

### Step 1: Delete `cleanRAM` from `Sources/Sampler.swift`
Remove `private var cleaningRAM = false` and `func cleanRAM(completion: ...)` (`Sampler.swift:340-396`).
**Verify**: typecheck exit 0; `rg -n "cleanRAM|cleaningRAM" Sources/Sampler.swift` → no matches.

### Step 2: Delete `cleanRAM` state, helper, and Memory card Clean button from `Sources/SinoApp.swift`
- Remove `@Published var cleaningRAM = false` and `@Published var cleanFeedback: String? = nil` (`:39-40`).
- Remove `func cleanRAM()` (`:917-938`).
- In `ramSection` (`:2968-3044`), remove the `headerTrailing: { ... }` block so it becomes `Card("MEMORY", "memorychip", pal) { ... }`.
**Verify**: typecheck exit 0; `./tests.sh` exit 0; `rg -n "cleanRAM|cleaningRAM|cleanFeedback|Quick RAM Clean" Sources` → no matches.

## Test plan

- Gates: Swift typecheck, `./tests.sh`, and zero `rg` matches for the removed symbols.

## Done criteria

- [ ] `rg -n "cleanRAM|cleaningRAM|cleanFeedback|Quick RAM Clean" Sources` returns no matches
- [ ] Swift typecheck and `./tests.sh` exit 0
- [ ] `git diff --stat` touches only `Sources/Sampler.swift` and `Sources/SinoApp.swift` (+ `plans/README.md`)

## STOP conditions

- Any other caller or Settings toggle references `cleanRAM`, `cleaningRAM`, or `cleanFeedback`.
