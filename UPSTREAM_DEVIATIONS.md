# Upstream deviations

This fork starts from upstream v2.7.3 at `16b0f11`. No upstream `dev` commit or pull request was merged or cherry-picked. Relevant development-branch ideas were treated as design references and implemented against the pinned baseline so unrelated behavior did not enter the release.

## Intentional production changes

- Long-lived observers, timers, tasks, capture sessions, media adapters, controller transports, and audio listeners now have explicit ownership and teardown.
- Image decoding, average-color work, artwork caches, Shelf thumbnails, Shelf persistence, drag previews, Quick Share discovery, and expensive file/image operations were bounded, made lazy, or moved away from the main actor.
- Notch boundary animation is centralized behind `StandardAnimations`, with a separate on/off switch and a 0.25×–3.0× speed preference. Gesture-interactive animation remains independent.
- Calendar and Reminders UI consumes a provider-neutral task model. Todoist is a separate actor-backed provider using Keychain credentials and incremental Sync API state.
- The fork adds configurable macOS Shortcut favorites, bounded Shelf search/Quick Look/clipboard/pinning/expiration actions, provider-backed quick task capture and editing, local timer/stopwatch/Pomodoro sessions, and optional per-display home layouts.
- A formal app-hosted XCTest target, deterministic mock networking, lifecycle/cache stress tests, performance capture scripts, repeatable run/package actions, and release verification were added.
- Unused direct dependencies on `Pow`, `Swift Collections`, and `SwiftUI Introspect` were removed.
- Marketing/build metadata for the hardening candidate is `2.7.3 (27304)`.

## Post-Beta 2 hardening

- Each visible agenda owns its date/results while all displays share a single actor-isolated EventKit store and calendar directory. Cancelled or superseded day loads cannot publish stale results. Calendar change notifications coalesce and invalidate visible agendas even when calendar metadata is unchanged.
- Calendar selection supports an empty selection. Recurring occurrences have distinct row identities without changing their Calendar deep links. The agenda uses a lazy vertical scroll view instead of the AppKit-backed List involved in the calendar freeze; controls and event/task actions are preserved.
- Date labels use Foundation's cached format style. Agenda sorting runs once per render; task snapshots sort once per refresh, use half-open date ranges, and avoid republishing unchanged task arrays.
- Local EventKit notification bursts only refresh Reminders and no longer force Todoist network syncs. Revoked Reminders access clears cached local tasks.
- Text/link Shelf items reuse two icon bitmaps, and text preview titles are capped at 80 characters while full text remains available for search and drag/copy. Shared thumbnails stop when the last consumer disappears; invalidation/memory pressure cancels pending work and prevents stale cache refill. Quick Look retains its panel reference long enough to close it.
- Artwork downloads are staged on disk and checked against the existing 20 MiB limit before image decoding, then downsampled to 512 pixels. This bounds memory even if a server sends more than the allowed amount.
- Window screen observers are removed per window; closing a window releases its hosting view. A Combine self-retain cycle in each notch model is removed. Shelf storage initializes only when the selected behavior needs its contents.

No new runtime dependencies or upstream development commits were introduced.

## Identity and update policy

The fork uses `com.k0g1.boringnotch.optimized` rather than the upstream bundle identifier. Its XPC and test bundle identifiers, service lookup, Keychain namespace, logging labels, TipKit lookup, and release cleanup paths follow that identity. This permits side-by-side installation but intentionally starts with separate settings, sandbox data, launch-at-login state, credentials, and privacy approvals.

The upstream Sparkle feed and public key are retained for a user-initiated compatibility check, but scheduled automatic checks are disabled. The fork does not yet publish a separately signed appcast. A future public release should replace the feed/key together and use Developer ID signing plus notarization.

## Known inherited constraints

- The app target supports macOS 14, while the existing XPC helper target declares macOS 15.5.
- Swift 5 builds pass under Xcode 16.4 but emit Swift 6 Sendable/MainActor migration warnings, including warnings at AppKit and third-party API boundaries.
- The source continues to depend on private MediaRemote behavior through the bundled adapter.
- The complete interactive regression matrix and hours-long soak remain manual because they require real displays, permissions, media applications, files, accounts, and user-visible interaction.
