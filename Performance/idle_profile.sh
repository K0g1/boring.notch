#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --app /path/to/app [--duration seconds] [--interval seconds] [--scenario name] [--output file.json]" >&2
}

APP_BUNDLE=""
DURATION=300
INTERVAL=15
SCENARIO="idle_5m"
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_BUNDLE="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --scenario) SCENARIO="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$APP_BUNDLE" && -d "$APP_BUNDLE" ]] || { usage; exit 2; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${OUTPUT:-$ROOT_DIR/Performance/Results/${SCENARIO}.json}"
mkdir -p "$(dirname "$OUTPUT")"

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_BUNDLE/Contents/Info.plist")"
BEFORE_PIDS="$(pgrep -x "$EXECUTABLE_NAME" 2>/dev/null || true)"
SAMPLES_FILE="$(mktemp -t boringnotch-profile.XXXXXX)"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]]; then
    pkill -P "$APP_PID" >/dev/null 2>&1 || true
    kill "$APP_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$SAMPLES_FILE"
}
trap cleanup EXIT

/usr/bin/open -n "$APP_BUNDLE"
for _ in {1..40}; do
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if ! grep -qx "$candidate" <<< "$BEFORE_PIDS"; then
      APP_PID="$candidate"
      break 2
    fi
  done < <(pgrep -x "$EXECUTABLE_NAME" 2>/dev/null || true)
  sleep 0.25
done

[[ -n "$APP_PID" ]] || { echo "Unable to identify the launched process" >&2; exit 1; }

START_EPOCH="$(date +%s)"
while kill -0 "$APP_PID" 2>/dev/null; do
  NOW_EPOCH="$(date +%s)"
  ELAPSED=$((NOW_EPOCH - START_EPOCH))
  CPU="$(ps -p "$APP_PID" -o %cpu= | awk '{$1=$1; print}')"
  RSS_KB="$(ps -p "$APP_PID" -o rss= | awk '{$1=$1; print}')"
  THREADS="$(ps -M "$APP_PID" | tail -n +2 | wc -l | awk '{$1=$1; print}')"
  CHILDREN="$( (pgrep -P "$APP_PID" 2>/dev/null || true) | wc -l | awk '{$1=$1; print}')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$ELAPSED" "${CPU:-0}" "${RSS_KB:-0}" "$THREADS" "$CHILDREN" >> "$SAMPLES_FILE"
  (( ELAPSED >= DURATION )) && break
  sleep "$INTERVAL"
done

kill -0 "$APP_PID" 2>/dev/null || { echo "Application exited during profiling" >&2; exit 1; }
VM_SUMMARY="$(vmmap -summary "$APP_PID" 2>/dev/null || true)"
PHYSICAL_MB="$(awk '/Physical footprint:/ {gsub(/[^0-9.]/, "", $3); print $3; exit}' <<< "$VM_SUMMARY")"
PEAK_MB="$(awk '/Physical footprint \(peak\):/ {gsub(/[^0-9.]/, "", $4); print $4; exit}' <<< "$VM_SUMMARY")"
COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"

python3 - "$SAMPLES_FILE" "$OUTPUT" "$COMMIT" "$SCENARIO" "$DURATION" "$INTERVAL" "${PHYSICAL_MB:-null}" "${PEAK_MB:-null}" <<'PY'
import json
import statistics
import sys
from datetime import datetime, timezone

samples_path, output, commit, scenario, duration, interval, physical, peak = sys.argv[1:]
rows = []
with open(samples_path, encoding="utf-8") as handle:
    for line in handle:
        elapsed, cpu, rss, threads, children = line.rstrip().split("\t")
        rows.append({
            "elapsedSeconds": int(elapsed),
            "cpuPercent": float(cpu),
            "rssMB": int(rss) / 1024,
            "threads": int(threads),
            "childProcesses": int(children),
        })

def number(value):
    return None if value == "null" else float(value)

result = {
    "schemaVersion": 1,
    "capturedAt": datetime.now(timezone.utc).isoformat(),
    "commit": commit,
    "scenario": scenario,
    "requestedDurationSeconds": int(duration),
    "sampleIntervalSeconds": int(interval),
    "sampleCount": len(rows),
    "physicalFootprintMB": number(physical),
    "physicalFootprintPeakMB": number(peak),
    "cpuAveragePercent": statistics.fmean(row["cpuPercent"] for row in rows),
    "rssAverageMB": statistics.fmean(row["rssMB"] for row in rows),
    "rssFirstMB": rows[0]["rssMB"],
    "rssLastMB": rows[-1]["rssMB"],
    "rssGrowthMB": rows[-1]["rssMB"] - rows[0]["rssMB"],
    "threadsPeak": max(row["threads"] for row in rows),
    "childProcessesPeak": max(row["childProcesses"] for row in rows),
    "samples": rows,
    "notes": "CPU is sampled from macOS ps %cpu; physical footprint is the final vmmap summary.",
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(result, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(output)
PY
