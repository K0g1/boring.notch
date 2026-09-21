# Performance suite

These tools record repeatable command-line evidence without requiring UI automation.

## Capture an idle run

```bash
./Performance/idle_profile.sh \
  --app /path/to/BoringNotch-Optimized.app \
  --duration 300 \
  --interval 15 \
  --scenario idle_5m
```

The profiler refuses to measure a process that has not completed initialization. Output is JSON under `Performance/Results/` unless `--output` is supplied. CPU comes from macOS `ps`; footprint comes from `vmmap`. Use stabilized samples rather than the startup sample when evaluating closed-notch idle CPU.

## Run lifecycle/cache stress tests

```bash
./Performance/lifecycle_stress.sh
```

This runs the app-hosted `LifecycleAndCacheTests`, including 1,000 face start/stop cycles, the thumbnail concurrency cap, reverse-index eviction, icon-cache cost accounting, and task filtering. It requires a locally installed Apple Development certificate because the hardened host and embedded frameworks must share a team identity.

## Build the unmodified baseline

```bash
./Performance/baseline.sh baseline-v2.7.3
```

This creates a detached worktree and never applies optimized source changes to the baseline. The checked-in baseline evidence was captured separately and is stored in `Performance/Baseline/`.

## Compare two JSON captures

```bash
./Performance/compare_results.py \
  Performance/Baseline/baseline_bounded_idle.json \
  Performance/Results/optimized_idle_2m.json
```

Durations and warm-up state must be considered when interpreting the table. The tool reports arithmetic differences and does not claim statistical significance.
