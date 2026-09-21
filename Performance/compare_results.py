#!/usr/bin/env python3
import json
import sys
from pathlib import Path


METRICS = (
    ("physicalFootprintMB", "Physical footprint", "MB"),
    ("cpuAveragePercent", "Average CPU", "%"),
    ("rssAverageMB", "Average RSS", "MB"),
    ("rssGrowthMB", "RSS growth", "MB"),
    ("threadsPeak", "Peak threads", ""),
    ("childProcessesPeak", "Peak child processes", ""),
)


def load(path: str) -> dict:
    with Path(path).open(encoding="utf-8") as handle:
        return json.load(handle)


def display(value, unit: str) -> str:
    if value is None:
        return "not measured"
    if isinstance(value, float):
        return f"{value:.2f}{unit}"
    return f"{value}{unit}"


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} baseline.json optimized.json", file=sys.stderr)
        return 2
    baseline = load(sys.argv[1])
    optimized = load(sys.argv[2])
    print("| Metric | Baseline | Optimized | Change |")
    print("|---|---:|---:|---:|")
    for key, label, unit in METRICS:
        before = baseline.get(key)
        after = optimized.get(key)
        delta = None if before is None or after is None else after - before
        print(
            f"| {label} | {display(before, unit)} | {display(after, unit)} | "
            f"{display(delta, unit)} |"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
