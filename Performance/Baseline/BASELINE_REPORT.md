# v2.7.3 Release baseline report

## Scope and source integrity

This report covers the strongest feasible baseline from the unmodified checkout requested by the product brief. The checkout was at commit `16b0f11f51c79d42e27c10d77fd9e53c11410fdb` (`v2.7.3`, `baseline-v2.7.3`). The coordinator's working tree was on `perf/lifecycle` with production edits, so all builds and launches below used a separate detached worktree at `/tmp/BoringNotch-baseline-v2.7.3`. No production source files were edited by this validation task. Only test/report artifacts under `Performance/Baseline/` were updated.

The shell resolves the requested workspace through OneDrive to `/Users/kevindeng/Library/CloudStorage/OneDrive-UBC/Documents/ChatGPT/BoringNotch`; Git sees the same checkout and reports clean status.

## Build status

An initial Release build attempt failed while full Xcode was unavailable. Xcode 16.4 was subsequently installed and selected at `/Applications/Xcode.app/Contents/Developer`. From the detached baseline worktree, package resolution completed (12 pins), `xcodebuild -list` succeeded, and both an unsigned Release build and a normal ad-hoc-signed Release build exited 0. The signed product passed `codesign --verify --deep --strict`. Exact commands/results are preserved in [BUILD_ATTEMPTS.txt](BUILD_ATTEMPTS.txt).

Consequences:

- Release `.app` compilation is verified; the successful ad-hoc product is under `/tmp/BoringNotch-baseline-v2.7.3-SignedDerivedData/Build/Products/Release/boringNotch.app`;
- this checkout declares only `boringNotch` and `BoringNotchXPCHelper` app targets (plus package schemes), with no test target;
- no archive/export/DMG was attempted for baseline;
- Instruments is not available as a shell command, so CLI diagnostics were used;
- UI-heavy scenarios remain manual/unexecuted per the brief.

## Host and project configuration

The host is macOS 15.7.3 (24G419), Apple M1 Pro (8 cores), 16 GB RAM, one built-in 3024×1964 Retina display. The project declares macOS 14.0 and Swift 5.0. The project file currently contains main-target marketing version `2.7.2`/build `262`, while the Git tag is `v2.7.3`; this version metadata discrepancy should be resolved by the build owner before release packaging. Full details are in [ENVIRONMENT.txt](ENVIRONMENT.txt).

## Scenario matrix

| Scenario | Status | Evidence / blocker |
|---|---|---|
| A fresh launch, untouched | partial | isolated Release app launched via temporary bundle ID; startup warnings recorded |
| B 5 min idle | partial | bounded ~2-minute idle observation; 5-minute duration not completed |
| C 30 min idle | blocked/manual | no 30-minute soak executed |
| D/E music playing/paused | blocked/manual | no controlled media state |
| F repeated open/close | blocked/manual | isolated build exists; no safe UI automation harness |
| G/H Shelf 0 / 100+ items | blocked/manual | isolated build exists; no representative user-data fixture |
| I/J Calendar enabled/disabled | blocked/manual | isolated build exists; no controlled permission/data state |
| K/L camera disabled/active | blocked/manual | no controlled build/permission state |
| M multiple displays | blocked | host has one display |
| N/O settings never/opened | blocked/manual | isolated build exists; settings interaction was not automated |
| P media-controller switching | blocked/manual | isolated build exists; no controlled media fixture |

## Isolated Release process observation

An ad-hoc Release app from the detached baseline worktree was copied to `/tmp/BoringNotch-baseline-v2.7.3-run.app` with temporary bundle identifier `com.codex.baseline.boringnotch`, then launched with `open -n` so it did not collide with the user's existing upstream process. The temporary bundle was terminated after measurements. This bundle-ID change is test-only; the executable and resources came from the unmodified baseline build.

At approximately 1:53 after launch, PID 2748 showed:

| Metric | Observation |
|---|---:|
| `vmmap` physical footprint | 249.9M |
| `vmmap` physical footprint peak | 287.5M |
| `ps` RSS | 169,728 KB |
| process thread rows | 5 |
| MediaRemote adapter child | 1 `/usr/bin/perl` |
| `leaks` report | 0 leaks / 0 bytes |
| `sample` idle call graph | main AppKit event wait; worker threads semaphore waits |

The bounded `ps` series (15-second spacing; `%cpu` is the macOS cumulative process field, not a true interval sample) was:

```text
2026-09-21T02:52:56Z  1.1%  204480 KB  6 thread rows  1 child
2026-09-21T02:53:11Z  0.1%  204448 KB  5 thread rows  1 child
2026-09-21T02:53:26Z  2.5%  160912 KB  5 thread rows  1 child
2026-09-21T02:53:41Z  0.0%  160816 KB  5 thread rows  1 child
```

The 5-second `sample` captured 4,333 samples of the main thread in `mach_msg2_trap` through AppKit's event loop and 8,666 samples in `semaphore_wait_trap` across two caulk worker threads. Runtime stderr contained four SwiftUI toolbar ambiguous-size warnings and one deprecated `AVCaptureDeviceTypeExternal` warning.

## Previously running app context (not authoritative)

An already-running AppTranslocated `boringNotch.app` reported bundle version `2.7.3 (271)` and remains context only. It was not terminated or modified. Its earlier observations remain in [RUNNING_APP_OBSERVATION.txt](RUNNING_APP_OBSERVATION.txt) and must not be combined with the isolated Release measurements above.

## Handoff / unblock

The baseline `.app` build and bounded idle profile are now available. Before using these as a complete acceptance baseline, run the remaining manual/UI scenarios (5/30-minute idle, playback states, Shelf fixtures, permissions, display matrix, settings, and controller switching) with the user's interactive setup. The project metadata still reports `2.7.2`/`262` despite the Git baseline tag `v2.7.3`; this discrepancy should be tracked before release packaging.
