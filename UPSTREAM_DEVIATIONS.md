# Upstream deviations

This fork starts from upstream v2.7.3 at `16b0f11`. No upstream `dev` commit or pull request was merged or cherry-picked. Relevant development-branch ideas were treated as design references and implemented against the pinned baseline so unrelated behavior did not enter the release.

## Intentional production changes

- Long-lived observers, timers, tasks, capture sessions, media adapters, controller transports, and audio listeners now have explicit ownership and teardown.
- Image decoding, average-color work, artwork caches, Shelf thumbnails, Shelf persistence, drag previews, Quick Share discovery, and expensive file/image operations were bounded, made lazy, or moved away from the main actor.
- Notch boundary animation is centralized behind `StandardAnimations`, with a separate on/off switch and a 0.25×–3.0× speed preference. Gesture-interactive animation remains independent.
- Calendar and Reminders UI consumes a provider-neutral task model. Todoist is a separate actor-backed provider using Keychain credentials and incremental Sync API state.
- A formal app-hosted XCTest target, deterministic mock networking, lifecycle/cache stress tests, performance capture scripts, repeatable run/package actions, and release verification were added.
- Unused direct dependencies on `Pow`, `Swift Collections`, and `SwiftUI Introspect` were removed.
- Marketing/build metadata is `2.7.3 (27301)`.

## Identity and update policy

The fork uses `com.k0g1.boringnotch.optimized` rather than the upstream bundle identifier. Its XPC and test bundle identifiers, service lookup, Keychain namespace, logging labels, TipKit lookup, and release cleanup paths follow that identity. This permits side-by-side installation but intentionally starts with separate settings, sandbox data, launch-at-login state, credentials, and privacy approvals.

The upstream Sparkle feed and public key are retained for a user-initiated compatibility check, but scheduled automatic checks are disabled. The fork does not yet publish a separately signed appcast. A future public release should replace the feed/key together and use Developer ID signing plus notarization.

## Known inherited constraints

- The app target supports macOS 14, while the existing XPC helper target declares macOS 15.5.
- Swift 5 builds pass under Xcode 16.4 but emit Swift 6 Sendable/MainActor migration warnings, including warnings at AppKit and third-party API boundaries.
- The source continues to depend on private MediaRemote behavior through the bundled adapter.
- The complete interactive regression matrix and hours-long soak remain manual because they require real displays, permissions, media applications, files, accounts, and user-visible interaction.
