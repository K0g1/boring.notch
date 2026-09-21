#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${BORING_NOTCH_RELEASE_DERIVED_DATA:-${TMPDIR:-/tmp}/BoringNotch-ReleaseDerivedData-$UID}"
DIST_DIR="${BORING_NOTCH_DIST_DIR:-$ROOT_DIR/Release}"
STAGING_DIR="${BORING_NOTCH_APP_STAGING_DIR:-${TMPDIR:-/tmp}/BoringNotch-ReleaseStaging-$UID}"
SOURCE_APP="$DERIVED_DATA/Build/Products/Release/boringNotch.app"
CLEAN_APP="$STAGING_DIR/BoringNotch-Optimized.app"
OUTPUT_APP="$DIST_DIR/BoringNotch-Optimized.app"
OUTPUT_DMG="$DIST_DIR/BoringNotch-Optimized.dmg"
OUTPUT_ZIP="$DIST_DIR/BoringNotch-Optimized.app.zip"
RELEASE_REPORTS=(BUILD_INFO.md PERFORMANCE_REPORT.md UPSTREAM_DEVIATIONS.md)
SIGNING_IDENTITY="${BORING_NOTCH_SIGNING_IDENTITY:-}"
SIGNING_TEAM="${BORING_NOTCH_SIGNING_TEAM:-}"

[[ "$DIST_DIR" != "/" && "$DIST_DIR" != "$ROOT_DIR" ]] || {
  echo "Refusing unsafe release directory: $DIST_DIR" >&2
  exit 2
}
[[ "$(basename "$CLEAN_APP")" == "BoringNotch-Optimized.app" ]] || exit 2
[[ "$(basename "$OUTPUT_APP")" == "BoringNotch-Optimized.app" ]] || exit 2

mkdir -p "$DIST_DIR" "$STAGING_DIR"

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
  echo "Signing with $SIGNING_IDENTITY (team $SIGNING_TEAM)"
else
  echo "No Apple Development identity is available." >&2
  echo "A hardened ad-hoc host cannot load this app's nested MediaRemote framework safely; refusing to produce a broken release." >&2
  exit 1
fi

xcodebuild \
  -project "$ROOT_DIR/boringNotch.xcodeproj" \
  -scheme boringNotch \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  "${SIGNING_ARGS[@]}" \
  build

rm -rf -- "$CLEAN_APP"
/usr/bin/ditto "$SOURCE_APP" "$CLEAN_APP"
xattr -cr "$CLEAN_APP"

codesign --verify --deep --strict --verbose=2 "$CLEAN_APP"
signature_team() {
  codesign -dvv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1
}

MAIN_TEAM="$(signature_team "$CLEAN_APP")"
HELPER_TEAM="$(signature_team "$CLEAN_APP/Contents/XPCServices/BoringNotchXPCHelper.xpc")"
MEDIA_TEAM="$(signature_team "$CLEAN_APP/Contents/Frameworks/MediaRemoteAdapter.framework")"
[[ -n "$MAIN_TEAM" && "$MAIN_TEAM" != "not set" ]] || {
  echo "Release app is not signed by an Apple development team." >&2
  exit 1
}
[[ "$MAIN_TEAM" == "$HELPER_TEAM" && "$MAIN_TEAM" == "$MEDIA_TEAM" ]] || {
  echo "Host, XPC helper, and MediaRemote framework have mismatched signing teams." >&2
  exit 1
}
rm -f "$OUTPUT_DMG"
hdiutil create \
  -volname "BoringNotch Optimized" \
  -srcfolder "$CLEAN_APP" \
  -ov \
  -format UDZO \
  "$OUTPUT_DMG"

rm -f "$OUTPUT_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$CLEAN_APP" "$OUTPUT_ZIP"

VERIFY_DIR="$(mktemp -d -t boringnotch-release-verify.XXXXXX)"
trap 'rm -rf -- "$VERIFY_DIR"' EXIT
/usr/bin/ditto -x -k "$OUTPUT_ZIP" "$VERIFY_DIR"
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/BoringNotch-Optimized.app"

# Keep a convenient workspace app as well. Cloud-sync software can later add
# FinderInfo/resource-fork metadata, so the ZIP remains the durable app artifact.
rm -rf -- "$OUTPUT_APP"
/usr/bin/ditto "$CLEAN_APP" "$OUTPUT_APP"
xattr -cr "$OUTPUT_APP"
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"

for report in "${RELEASE_REPORTS[@]}"; do
  [[ -f "$ROOT_DIR/$report" ]] || {
    echo "Missing required release report: $ROOT_DIR/$report" >&2
    exit 1
  }
  /usr/bin/ditto "$ROOT_DIR/$report" "$DIST_DIR/$report"
done

(
  cd "$DIST_DIR"
  shasum -a 256 BoringNotch-Optimized.app/Contents/MacOS/boringNotch \
    BoringNotch-Optimized.app.zip \
    BoringNotch-Optimized.dmg \
    "${RELEASE_REPORTS[@]}" > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)

echo "Created:"
echo "  $OUTPUT_APP"
echo "  $OUTPUT_ZIP"
echo "  $OUTPUT_DMG"
echo "  $DIST_DIR/SHA256SUMS.txt"
for report in "${RELEASE_REPORTS[@]}"; do
  echo "  $DIST_DIR/$report"
done
echo "Clean staging app retained at:"
echo "  $CLEAN_APP"
