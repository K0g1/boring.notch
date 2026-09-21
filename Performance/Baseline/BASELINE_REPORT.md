# v2.7.3 Release baseline report

## Scope and source integrity

This report covers the strongest feasible baseline from the unmodified checkout requested by the product brief. The checkout was at `optimized-v2.7.3`, commit `16b0f11f51c79d42e27c10d77fd9e53c11410fdb` (`v2.7.3`, `baseline-v2.7.3`) with a clean working tree. No production source files were edited. Only test/report artifacts under `Performance/Baseline/` were added.

The shell resolves the requested workspace through OneDrive to `/Users/kevindeng/Library/CloudStorage/OneDrive-UBC/Documents/ChatGPT/BoringNotch`; Git sees the same checkout and reports clean status.

## Build status

The required Release build could not be attempted beyond tool discovery. `xcode-select -p` points to `/Library/Developer/CommandLineTools`; `xcodebuild` rejects that developer directory because a full Xcode installation is required. `/Applications` contains no `Xcode*.app`, and `instruments` is not installed. Both `xcodebuild` commands and their raw failures are preserved in [BUILD_ATTEMPTS.txt](BUILD_ATTEMPTS.txt).

Consequences:

- no Release compile, test target, archive, signing, export, `.app`, or `.dmg` was produced from this checkout;
- Swift package resolution through Xcode could not be verified;
- Instruments scenarios are blocked;
- UI-heavy scenarios remain manual/unexecuted per the brief.

## Host and project configuration

The host is macOS 15.7.3 (24G419), Apple M1 Pro (8 cores), 16 GB RAM, one built-in 3024×1964 Retina display. The project declares macOS 14.0 and Swift 5.0. The project file currently contains main-target marketing version `2.7.2`/build `262`, while the Git tag is `v2.7.3`; this version metadata discrepancy should be resolved by the build owner before release packaging. Full details are in [ENVIRONMENT.txt](ENVIRONMENT.txt).

## Scenario matrix

| Scenario | Status | Evidence / blocker |
|---|---|---|
| A fresh launch, untouched | blocked | no checkout Release build; existing running app is uncontrolled |
| B 5 min idle | blocked | no controlled checkout build |
| C 30 min idle | blocked | no controlled checkout build |
| D/E music playing/paused | blocked/manual | no controlled build and no controlled media state |
| F repeated open/close | blocked/manual | no controlled build; no automation harness |
| G/H Shelf 0 / 100+ items | blocked/manual | no controlled build/data fixture |
| I/J Calendar enabled/disabled | blocked/manual | no controlled build/permission state |
| K/L camera disabled/active | blocked/manual | no controlled build/permission state |
| M multiple displays | blocked | host has one display |
| N/O settings never/opened | blocked/manual | no controlled build |
| P media-controller switching | blocked/manual | no controlled build/media fixture |

## Secondary process observation (not authoritative)

An already-running AppTranslocated `boringNotch.app` reported bundle version `2.7.3 (271)` and was observed for context only. It had been running for about 57 minutes at capture, with two `/usr/bin/perl` MediaRemote adapter children. `vmmap -summary` reported physical footprint `309.2M`, peak `542.2M`; `leaks` could inspect readonly memory only and listed `12 leaks / 1,728 bytes`. A four-reading, 10-second-spacing `ps` series averaged `0.65%` instantaneous CPU and showed 33.3–45.0 MiB RSS. These values are not controlled Release measurements and must not be used as before/after claims. Raw details are in [RUNNING_APP_OBSERVATION.txt](RUNNING_APP_OBSERVATION.txt).

## Handoff / unblock

Install/select a full Xcode release (matching the project's Swift/Xcode requirements), then rerun the exact command in `BUILD_ATTEMPTS.txt` with a clean checkout and controlled scenario matrix. Capture Activity Monitor/`vmmap`/`sample`/`heap`/`leaks`/Instruments data per scenario before any production edit. Preserve these reports as the pre-change reference.

