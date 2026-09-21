#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${BORING_NOTCH_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/BoringNotch-TestDerivedData-$UID}"
SIGNING_IDENTITY="${BORING_NOTCH_SIGNING_IDENTITY:-}"
SIGNING_TEAM="${BORING_NOTCH_SIGNING_TEAM:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
      | head -n 1
  )"
fi
[[ -n "$SIGNING_IDENTITY" ]] || {
  echo "No Apple Development identity is available for the app-hosted test suite." >&2
  exit 1
}
if [[ -z "$SIGNING_TEAM" ]]; then
  SIGNING_TEAM="$(
    security find-certificate -c "$SIGNING_IDENTITY" -p 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null \
      | sed -E 's/.*OU=([^,]+).*/\1/'
  )"
fi
[[ -n "$SIGNING_TEAM" ]] || {
  echo "Unable to determine the signing team for $SIGNING_IDENTITY." >&2
  exit 1
}

xcodebuild \
  -project "$ROOT_DIR/boringNotch.xcodeproj" \
  -scheme boringNotch \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:boringNotchTests/LifecycleAndCacheTests \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  "CODE_SIGN_IDENTITY=Apple Development" \
  "DEVELOPMENT_TEAM=$SIGNING_TEAM" \
  PROVISIONING_PROFILE_SPECIFIER= \
  test
