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
    for _ in {1..20}; do
      kill -0 "$APP_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$APP_PID" >/dev/null 2>&1 || true
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

# A one-thread, low-RSS process is still inside sandbox/bootstrap setup and is
# not a running application. Refuse to record that state as an idle profile.
READY=0
for _ in {1..60}; do
  kill -0 "$APP_PID" 2>/dev/null || break
  READY_RSS="$(ps -p "$APP_PID" -o rss= | awk '{$1=$1; print}')"
  READY_THREADS="$(ps -M "$APP_PID" | tail -n +2 | wc -l | awk '{$1=$1; print}')"
  if [[ "${READY_RSS:-0}" -ge 10240 && "${READY_THREADS:-0}" -ge 2 ]]; then
    READY=1
    break
  fi
  sleep 0.25
done
[[ "$READY" -eq 1 ]] || {
  echo "Application did not finish initialization (pid=$APP_PID rssKB=${READY_RSS:-0} threads=${READY_THREADS:-0})" >&2
  exit 1
}

START_EPOCH="$(date +%s)"
while kill -0 "$APP_PID" 2>/dev/null; do
  NOW_EPOCH="$(date +%s)"
  ELAPSED=$((NOW_EPOCH - START_EPOCH))
  CPU="$(ps -p "$APP_PID" -o %cpu= | awk '{$1=$1; print}')"
  CPU_TIME="$(ps -p "$APP_PID" -o time= | awk '{$1=$1; print}')"
  RSS_KB="$(ps -p "$APP_PID" -o rss= | awk '{$1=$1; print}')"
  THREADS="$(ps -M "$APP_PID" | tail -n +2 | wc -l | awk '{$1=$1; print}')"
  CHILDREN="$( (pgrep -P "$APP_PID" 2>/dev/null || true) | wc -l | awk '{$1=$1; print}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ELAPSED" "${CPU:-0}" "${RSS_KB:-0}" "$THREADS" "$CHILDREN" "${CPU_TIME:-0}" >> "$SAMPLES_FILE"
  (( ELAPSED >= DURATION )) && break
  sleep "$INTERVAL"
done

kill -0 "$APP_PID" 2>/dev/null || { echo "Application exited during profiling" >&2; exit 1; }
VM_SUMMARY="$(vmmap -summary "$APP_PID" 2>/dev/null || true)"
PHYSICAL_MB="$(awk '/Physical footprint:/ {print $3; exit}' <<< "$VM_SUMMARY")"
PEAK_MB="$(awk '/Physical footprint \(peak\):/ {print $4; exit}' <<< "$VM_SUMMARY")"
COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
EXECUTABLE_SHA="$(shasum -a 256 "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" | awk '{print $1}')"

python3 - "$SAMPLES_FILE" "$OUTPUT" "$COMMIT" "$SCENARIO" "$DURATION" "$INTERVAL" "${PHYSICAL_MB:-null}" "${PEAK_MB:-null}" "$APP_BUILD" "$EXECUTABLE_SHA" <<'PY'
import json
import statistics
import sys
from datetime import datetime, timezone

samples_path, output, commit, scenario, duration, interval, physical, peak, app_build, executable_sha = sys.argv[1:]

def cpu_seconds(value):
    total = 0.0
    for part in value.split(":"):
        total = total * 60 + float(part)
    return total

rows = []
with open(samples_path, encoding="utf-8") as handle:
    for line in handle:
        elapsed, cpu, rss, threads, children, cpu_time = line.rstrip().split("\t")
        rows.append({
            "elapsedSeconds": int(elapsed),
            "cpuPercent": float(cpu),
            "cpuTimeSeconds": cpu_seconds(cpu_time),
            "rssMB": int(rss) / 1024,
            "threads": int(threads),
            "childProcesses": int(children),
        })

def megabytes(value):
    if value == "null":
        return None
    value = value.strip()
    units = {"K": 1 / 1024, "M": 1, "G": 1024, "T": 1024 * 1024}
    suffix = value[-1].upper()
    if suffix in units:
        return float(value[:-1]) * units[suffix]
    return float(value)

stabilized = [row for row in rows if row["elapsedSeconds"] >= 30]
stable_cpu = None
if len(stabilized) > 1:
    elapsed = stabilized[-1]["elapsedSeconds"] - stabilized[0]["elapsedSeconds"]
    if elapsed > 0:
        stable_cpu = 100 * (stabilized[-1]["cpuTimeSeconds"] - stabilized[0]["cpuTimeSeconds"]) / elapsed

result = {
    "schemaVersion": 1,
    "capturedAt": datetime.now(timezone.utc).isoformat(),
    "commit": commit,
    "appBuild": app_build,
    "executableSHA256": executable_sha,
    "scenario": scenario,
    "requestedDurationSeconds": int(duration),
    "sampleIntervalSeconds": int(interval),
    "sampleCount": len(rows),
    "physicalFootprintMB": megabytes(physical),
    "physicalFootprintPeakMB": megabytes(peak),
    "cpuAveragePercent": statistics.fmean(row["cpuPercent"] for row in rows),
    "stabilizedCPUPercent": stable_cpu,
    "rssAverageMB": statistics.fmean(row["rssMB"] for row in rows),
    "rssFirstMB": rows[0]["rssMB"],
    "rssLastMB": rows[-1]["rssMB"],
    "rssGrowthMB": rows[-1]["rssMB"] - rows[0]["rssMB"],
    "threadsPeak": max(row["threads"] for row in rows),
    "childProcessesPeak": max(row["childProcesses"] for row in rows),
    "samples": rows,
    "notes": "cpuAveragePercent averages ps snapshots (including startup). stabilizedCPUPercent uses cumulative process CPU time from 30 seconds onward. Physical footprint is the final vmmap summary. commit identifies the profiler checkout; appBuild and executableSHA256 identify the binary.",
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(result, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(output)
PY
