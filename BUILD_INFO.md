# BoringNotch Optimized build information

## Beta 1

- Upstream baseline: `TheBoredTeam/boring.notch` v2.7.3, commit `16b0f11f51c79d42e27c10d77fd9e53c11410fdb`
- Optimized source used for the packaged binary: `44b780e`
- Version: `2.7.3` (`CFBundleVersion` `27302`)
- Main bundle identifier: `com.k0g1.boringnotch.optimized`
- XPC bundle identifier: `com.k0g1.boringnotch.optimized.BoringNotchXPCHelper`
- Architectures: Apple Silicon and Intel (`arm64`, `x86_64`)
- Deployment target: macOS 14.0 for the app; the inherited upstream XPC target remains macOS 15.5

## Build environment

- macOS 15.7.3 (24G419)
- MacBook Pro with Apple M1 Pro, 8 CPU cores, 16 GB RAM
- One built-in 3024×1964 Retina display
- Xcode 16.4 (16F6)
- macOS 15.5 SDK
- Swift 5 language mode with targeted strict-concurrency checking

The release artifacts were produced with:

```bash
./script/package_release.sh
```

This beta includes favorite macOS Shortcuts, Shelf search/Quick Look/clipboard
paste/pinning/rename/expiration controls, quick task capture and editing for
Reminders and Todoist, timer/stopwatch/Pomodoro sessions, and optional
per-display home layouts.

The script locates an Apple Development identity, resolves its team, performs a universal Release build with automatic signing, stages the app outside the OneDrive workspace, verifies aligned signing teams for the app/XPC/MediaRemote framework, and deep-verifies both the staged app and the ZIP extraction. It refuses to publish a hardened ad-hoc build because that configuration did not load the embedded media framework reliably.

## Artifacts

The app, ZIP, DMG, and reports are under `Release/`. Their authoritative hashes are in `Release/SHA256SUMS.txt`, generated only after the final signing/package pass and successfully checked from that directory with `shasum -a 256 -c SHA256SUMS.txt`. Keeping hashes out of this source report avoids a circular package input where updating the report changes its own release checksum.

The ZIP is the durable copy of the verified app. It was created from the clean temporary staging app with `ditto -c -k --sequesterRsrc --keepParent`, extracted into a new temporary directory, and deep-signature verified there. A convenient unpacked app is also present in `Release/`, but OneDrive may later add FinderInfo or resource-fork metadata to that workspace copy. Re-extract the ZIP if cloud metadata invalidates the unpacked copy.

## Signing and installability

The app, XPC helper, and embedded frameworks are hardened and signed with the locally available Apple Development certificate for team `XKFS7H8QQ8`. `codesign --verify --deep --strict` passes for the staged app, extracted ZIP app, and workspace app. A signed Release launch completed initialization and remained healthy during the two-minute profile.

This is a personal development build, not a public distribution build. No Developer ID Application identity or notarization credentials were available, so notarization and stapling were not performed. `spctl --assess` rejects the bundle as expected. Other Macs may refuse it or require a locally trusted development identity. A public release still requires Developer ID signing, Apple notarization, stapling, and a fresh Gatekeeper assessment.

## Fork identity and migration

The optimized bundle uses a fork-specific identity so it can coexist with upstream. The main app, unit-test bundle, XPC service name, XPC client lookup, Todoist Keychain namespace, logging/tooling identifiers, TipKit icon lookup, and release cleanup paths were updated together.

The isolation is intentional but means the upstream app's preferences, launch-at-login registration, sandbox container, Shelf bookmarks/cache, Todoist token, accessibility approval, Apple Events approval, camera/calendar access, and other privacy grants are not migrated automatically. Configure or approve those again in the optimized app. The Todoist token remains Keychain-only under `com.k0g1.boringnotch.optimized.todoist-api-token`.

Automatic Sparkle checks are disabled so the optimized fork cannot silently replace itself with an upstream build. The explicit manual update action still points at the upstream feed; using it may install an upstream release and should therefore be intentional until the fork owns a signed appcast.

## Verification summary

- Universal Release build: passed
- Strict deep signature verification: passed
- ZIP extraction and signature verification: passed
- Artifact checksum verification: passed
- Signed Release launch/readiness: passed
- Debug app-hosted XCTest suite: 21 tests passed, 0 failures
- 1,000-cycle face lifecycle stress test: passed
- Post-test and post-profile orphan process check: passed
- Release XCTest: not run by design; the production configuration keeps `ENABLE_TESTABILITY=NO`
- Gatekeeper/notarization: not passed; requires Developer ID and notarization credentials
- UI/privacy/media matrix and long soak: not run; see `PERFORMANCE_REPORT.md`

The build emits existing Swift 6 migration diagnostics while compiling in Swift 5 mode, including Sendable/MainActor warnings in AppKit and third-party boundaries. They are warnings in Xcode 16.4, not build failures, but remain future migration work.
