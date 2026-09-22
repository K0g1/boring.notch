# BoringNotch Optimized performance report

## Decision

The measured signed Release build meets the requested fresh-idle memory target and the closed-notch stabilized CPU target on the available Apple Silicon machine. The hardening work also adds regression coverage for a reproduced notch-model retain cycle, calendar request races, stale agenda rows, Shelf cancellation, bounded artwork, and local-only Reminder invalidation. This evidence supports a beta release; it is not a production/notarization sign-off.

This is a beta decision for the automated scope, not a claim that the unrun 30-minute, multi-display, live-media, or real-Todoist scenarios passed.

## Measurement context

Both measurements were taken on the same MacBook Pro (M1 Pro, 8 CPU cores, 16 GB RAM, one built-in display) with macOS 15.7.3 and Xcode 16.4. The baseline is the unmodified v2.7.3 commit `16b0f11`; the Beta 2 capture is the Apple Development-signed universal Release app from `81b6863`. Build 27304 is the later hardening candidate.

The baseline evidence is a bounded four-sample observation near 1:53 after launch. Beta 2 had a 120-second capture with 13 samples. The hardening candidate was packaged and signed as build 27304; its fresh capture should be repeated with the final artifact after installation on the target machine. These are useful directional measurements but not statistically controlled benchmarks. `ps` supplies CPU and RSS; `vmmap -summary` supplies physical footprint. Raw evidence is under `Performance/Baseline/` and `Performance/Results/`.

## Before and after

| Metric | v2.7.3 baseline | Optimized | Change |
|---|---:|---:|---:|
| Final physical footprint | 249.9 MB | 20.5 MB (Beta 2) | -229.4 MB (-91.8%) |
| Peak physical footprint | 287.5 MB | 20.8 MB (Beta 2) | -266.7 MB (-92.8%) |
| Average RSS in captured series | 178.38 MiB | 53.54 MiB (Beta 2) | -124.85 MiB (-70.0%) |
| Average sampled CPU, whole series | 0.925% | 0.815% (Beta 2) | -0.110 percentage points |
| Hardening candidate physical footprint | not measured | 28.5 MB in an earlier 180-second run | requires a clean final-artifact capture |
| Hardening candidate RSS growth | not measured | -2.578 MiB in that earlier run | requires a clean final-artifact capture |
| Peak thread rows | 6 | 7 | +1 |
| Peak child processes | 1 | 1 | no change |

The optimized whole-series CPU average includes startup. The hardening profiler now records cumulative process CPU time and reports the stabilized interval separately; this prevents one `ps` sample from being mistaken for sustained idle work. The baseline RSS fell by 42.64 MiB during its short sample window because of a memory purge, so that value is not presented as a growth comparison.

## Resource stability evidence

- The signed Release app completed initialization, held seven thread rows when stabilized, and owned one expected MediaRemote adapter child.
- Graceful app termination and app-hosted XCTest teardown left no `boringNotch` or MediaRemote adapter process behind.
- The face lifecycle test completed 1,000 start/stop cycles, rejected a second concurrent blink task each time, and returned to the stopped state after every cycle.
- Thumbnail generation was capped at four concurrent operations in stress testing.
- The thumbnail reverse index and image cache share a hard 100-entry bound; a 250-item test evicted the oldest 150 metadata/image keys.
- Shelf icon cache entries are costed from pixel dimensions, making its total-cost limit effective.
- Leak snapshots at 15 and 60 seconds both reported the same two root leaks totaling 368 bytes. The fixed count/size did not grow over the observed 45-second interval, but it is not a zero-leak result.
- The media-controller lifecycle now has explicit start/stop ownership. The MediaRemote adapter receives synchronous termination on teardown, and repeated app-hosted test runs no longer leave adapter processes behind.

## Feature-related performance changes

- Long-lived media timers, notification streams, WebSocket/reconnect work, artwork requests, CoreAudio listeners, visualizer animation, webcam capture, fullscreen observation, Quick Share discovery, and settings resources now follow explicit feature/view lifecycles.
- Album art and Shelf images are downsampled before display, average color uses sampled bitmap data, Core Image contexts are reused, and URL/image caches are bounded.
- Shelf thumbnail work is lazy, de-duplicated, concurrency-limited, cancellable, and kept out of computed view properties. Persistence and expensive processing move off the main actor where practical.
- Three unused direct packages (`Pow`, `Swift Collections`, and `SwiftUI Introspect`) were removed; nine package pins remain.
- Todoist uses an ephemeral URL session with no URL cache. It performs one full Sync API request, persists a sync token and compact task/project/section snapshots, then uses incremental sync. Concurrent refresh requests coalesce. It refreshes on activation, explicit request, or every 60 seconds only while a task view has visible consumers; there is no closed-notch periodic poll.
- Beta additions keep work bounded and visible-only: Shortcut favorites store at most six names, Shelf ingestion is capped at 200 items with size limits, task mutations serialize through the existing provider store, focus sessions use one completion timer plus a one-second `TimelineView` only while visible, and home layouts persist small value-only panel lists keyed by display UUID.

## Automated tests

The signed Debug app-hosted suite passed 38 of 38 tests:

- 3 animation policy tests, covering the 0.25×–3.0× clamp, predictable open/close response scaling, and disabled-animation transactions;
- lifecycle/cache/task-filter tests, including the 1,000-cycle face test, 1,000 discarded notch-model lifecycles, bounded Shelf behavior, thumbnail cancellation, and artwork size limits;
- calendar regression tests for rapid date changes, cancellation, out-of-order results, independent display days, empty calendar selection, recurring occurrence IDs, and coalesced EventKit notifications;
- task refresh regression tests for keeping local EventKit notifications out of Todoist sync and avoiding unchanged task publications;
- 7 Todoist HTTP client tests, covering request shape, close/reopen endpoints, authentication errors, malformed data, typed status errors, and bounded rate-limit retries;
- 6 Todoist provider tests, covering full/incremental sync, deletion/rename, optimistic completion, offline cache, credential separation, refresh coalescing, and flexible payload decoding.

The production Release target deliberately remains non-testable. Release compilation and runtime were validated separately rather than weakening `ENABLE_TESTABILITY` in the shipped build.

## Acceptance matrix

| Acceptance item | Status | Evidence or remaining work |
|---|---|---|
| Fresh idle physical footprint ≤60 MB preferred | passed for Beta 2 | 20.5 MB final, 20.8 MB peak |
| Closed-notch idle CPU <0.5–1% | passed for Beta 2 bounded run | 0.05% average from 30–120 seconds |
| 30-minute growth <5 MB | not run | a 30-minute run with the hardening feature matrix is still required |
| 1,000 lifecycle cycles stable | passed for face task owner | automated start/stop test; system-wide timer count was not instrumented |
| 100 controller switches | not run | teardown/orphan behavior passed tests and launch checks; live-controller matrix remains manual |
| Shelf cache hard bounded | passed | unit tests for concurrency, reverse index, and icon cost |
| Todoist closed idle negligible | not measured with a real account | design has no closed-view polling; mock transport tests passed |
| Multi-display memory | not run | only one physical display was available |
| Long-running representative soak | not run | requires interactive fixtures and hours of wall time |

The beta-specific additions were compile-checked and covered by the existing
38-test Debug suite where they share provider/cache/lifecycle infrastructure,
but the complete interactive matrix for Shortcut execution, Quick Look,
clipboard paste, task permissions, timers, and multi-display layout remains
manual.

## Manual validation still required

The user should exercise notch hover/click/gesture/shortcut opening and closing at several animation speeds; multiple displays; fullscreen and lock/unlock; Now Playing, Apple Music, Spotify, and YouTube Music switching; album art, lyrics, favorite, volume/brightness/HUD/battery behavior; Shelf drag/drop, persistence, Quick Look, Quick Share, compression and image tools; Calendar/Reminders permissions; camera; settings and launch at login; real Keychain persistence; a real Todoist account including project selection, due/undated tasks, offline recovery, completion/reopen, recurrence, and deep links; and explicit/manual Sparkle behavior.

For a long soak, run `Performance/idle_profile.sh` for at least 1,800 seconds while periodically exercising those flows, and verify that memory plateaus. Instruments Time Profiler/Leaks and visual animation timing were not automated in this environment.
