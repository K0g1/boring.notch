#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${BORING_NOTCH_DERIVED_DATA:-${TMPDIR:-/tmp}/BoringNotch-DebugDerivedData-$UID}"
APP_NAME="boringNotch"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
BUNDLE_ID="com.k0g1.boringnotch.optimized"
SIGNING_IDENTITY="${BORING_NOTCH_SIGNING_IDENTITY:-}"
SIGNING_TEAM="${BORING_NOTCH_SIGNING_TEAM:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
      | head -n 1
  )"
fi

SIGNING_ARGS=()
if [[ -n "$SIGNING_IDENTITY" ]]; then
  if [[ -z "$SIGNING_TEAM" ]]; then
    SIGNING_TEAM="$(
      security find-certificate -c "$SIGNING_IDENTITY" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -E 's/.*OU=([^,]+).*/\1/'
    )"
  fi
  [[ -n "$SIGNING_TEAM" ]] || {
    echo "Unable to determine the team for signing identity: $SIGNING_IDENTITY" >&2
    exit 1
  }
  SIGNING_ARGS=(
    "-allowProvisioningUpdates"
    "CODE_SIGN_STYLE=Automatic"
    "CODE_SIGN_IDENTITY=Apple Development"
    "DEVELOPMENT_TEAM=$SIGNING_TEAM"
    "PROVISIONING_PROFILE_SPECIFIER="
  )
else
  echo "No Apple Development identity is available; the hardened app cannot be launched reliably." >&2
  exit 1
fi

build_app() {
  xcodebuild \
    -project "$ROOT_DIR/boringNotch.xcodeproj" \
    -scheme boringNotch \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet \
    "${SIGNING_ARGS[@]}" \
    build
}

stop_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stop_running_app
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      pgrep -x "$APP_NAME" >/dev/null && exit 0
      sleep 0.25
    done
    echo "$APP_NAME did not remain running" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
