# Plan 002: Per-core CPU labels match the real efficiency/performance layout

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c497768..HEAD -- Sources/Sampler.swift Sources/CoreParsers.swift Tests/CoreParsersTests.swift`
> Expected changes: the WIP commit (CoreParsers.swift) and plan 001 (Tests/CoreParsersTests.swift).
> If `Sources/Sampler.swift` changed, compare the excerpt below to the live code; on a mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/001-build-the-working-tree.md
- **Category**: bug
- **Planned at**: commit `c497768` + uncommitted WIP, 2026-11-17

## Why this matters

The CPU card labels each core "Performance Core #n" or "Efficiency Core #n". The code assumes
`host_processor_info` lists performance cores first. On Apple Silicon it lists **efficiency cores
first**: on the owner's M3 Pro, `ioreg -l -p IODeviceTree | rg -o '"cluster-type" = <"[EP]">'` prints six
`E` then five `P`. So 5 of 6 E-cores are shown as "Performance", and every P-core as "Efficiency" —
every per-core reading is mislabeled. A correct, pure helper already exists (`CPUCoreLayout.label` in
`Sources/CoreParsers.swift`); the sampler just doesn't use it.

## Current state

- `Sources/Sampler.swift:196-197` — counts come from sysctl:
  `eCores = sysctlInt("hw.perflevel1.logicalcpu") ?? 0`, `pCores = sysctlInt("hw.perflevel0.logicalcpu") ?? 0`.
- `Sources/Sampler.swift:328-339` — the wrong labeling (`cores` is the count returned by `host_processor_info`):
  ```swift
            // host_processor_info lists P-cores first on Apple Silicon
            let p = (pCores > 0 && eCores + pCores == cores) ? pCores : 0
            s.cores = coreUsage.enumerated().map { i, v in
                let name: String
                if p > 0, i < p {
                    name = "Performance Core #\(i + 1)"
                } else if p > 0 {
                    name = "Efficiency Core #\(i - p + 1)"
                } else {
                    name = "Core #\(i + 1)"
                }
                return CoreSample(id: i, name: name, usage: v)
            }
  ```
- `Sources/CoreParsers.swift:18-30` — the correct helper:
  ```swift
  enum CPUCoreLayout {
      static func label(index: Int, eCores: Int, pCores: Int, totalCores: Int) -> String {
          if eCores > 0, pCores > 0, eCores + pCores == totalCores {
              if index < eCores { return "Efficiency Core #\(index + 1)" }
              return "Performance Core #\(index - eCores + 1)"
          }
          return "Core #\(index + 1)"
      }
  }
  ```
- Test convention: `Tests/CoreParsersTests.swift` (created by plan 001), FoldCoreTests style `check(...)`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `swiftc -typecheck -parse-as-library -module-name Sino -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -import-objc-header Sources/Bridging.h Sources/*.swift` | exit 0 |
| Tests | `./tests.sh` | exit 0, `core parsers: all checks passed` |
| Core order on this Mac | `ioreg -l -p IODeviceTree \| rg -o '"cluster-type" = <"[EP]">'` | E lines before P lines |

## Scope

**In scope**: `Sources/Sampler.swift` (only lines ~328–339), `Tests/CoreParsersTests.swift`.

**Out of scope**: any other part of `sampleCPU`; the per-core UI in `SinoApp.swift`; `CoreParsers.swift` itself.

## Git workflow

- Branch `advisor/002-core-labels`; commit `fix(cpu): label efficiency cores first, as Apple Silicon lists them`. Do not push.

## Steps

### Step 1: Add failing-first tests for the layout
In `Tests/CoreParsersTests.swift` add checks:
- 6E+5P, total 11: index 0 → `Efficiency Core #1`, 5 → `Efficiency Core #6`, 6 → `Performance Core #1`, 10 → `Performance Core #5`
- 4E+4P (M1), total 8: index 3 → `Efficiency Core #4`, 4 → `Performance Core #1`
- counts don't add up (6E+5P, total 12): index 0 → `Core #1`
- eCores 0 (e.g. Intel/VM): index 2 → `Core #3`

**Verify**: `./tests.sh` → exit 0 (the helper is already correct; these lock it in).

### Step 2: Use the helper in the sampler
Replace the block quoted above with:
```swift
            s.cores = coreUsage.enumerated().map { i, v in
                CoreSample(id: i, name: CPUCoreLayout.label(index: i, eCores: eCores, pCores: pCores, totalCores: cores), usage: v)
            }
```
Pass `cores` (the host_processor_info count), not `totalCores`, to preserve the existing guard semantics.
Delete the stale "P-cores first" comment and the now-unused `let p = …` line.

**Verify**: typecheck → exit 0; `rg -n "P-cores first|Performance Core #" Sources/Sampler.swift` → no matches.

## Test plan

- 9 new checks in `Tests/CoreParsersTests.swift` (Step 1). `./tests.sh` → exit 0.
- Optional, operator-approved: `./build.sh`, open the CPU card, run a single-threaded load
  (`yes > /dev/null &`, then `kill %1`): the busiest core should usually be labeled "Performance Core".

## Done criteria

- [ ] Typecheck exits 0; `./tests.sh` exits 0
- [ ] `rg -n "CPUCoreLayout.label" Sources/Sampler.swift` → 1 match
- [ ] `git status --short` lists only the two in-scope files (+ `plans/README.md`)
- [ ] `plans/README.md` row updated

## STOP conditions

- The `ioreg` command prints P before E on the executor's machine (the assumption "E-cores first" is false there).
- The excerpt at `Sampler.swift:328-339` doesn't match.

## Maintenance notes

- If Apple ships a chip with three core tiers, `hw.perflevel2.logicalcpu` appears and this labeling
  falls back to "Core #n" (counts won't add up) — acceptable, not wrong.
