#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${BORING_NOTCH_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/BoringNotch-TestDerivedData-$UID}"

xcodebuild \
  -project "$ROOT_DIR/boringNotch.xcodeproj" \
  -scheme boringNotch \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:boringNotchTests/LifecycleAndCacheTests \
  test
