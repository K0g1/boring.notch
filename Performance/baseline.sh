#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF="${1:-baseline-v2.7.3}"
OUTPUT_DIR="${2:-$ROOT_DIR/Performance/Artifacts/Baseline}"
WORKTREE="$(mktemp -d -t boringnotch-baseline.XXXXXX)"
DERIVED_DATA="$(mktemp -d -t boringnotch-baseline-derived.XXXXXX)"

cleanup() {
  git -C "$ROOT_DIR" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$DERIVED_DATA"
}
trap cleanup EXIT

rmdir "$WORKTREE"
git -C "$ROOT_DIR" worktree add --detach "$WORKTREE" "$BASE_REF"
xcodebuild \
  -project "$WORKTREE/boringNotch.xcodeproj" \
  -scheme boringNotch \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  build

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/boringNotch.app"
/usr/bin/ditto "$DERIVED_DATA/Build/Products/Release/boringNotch.app" "$OUTPUT_DIR/boringNotch.app"
echo "$OUTPUT_DIR/boringNotch.app"
