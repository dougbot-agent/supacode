# Energy Investigation Report

## Summary

This pass focused on the macOS Ghostty surface bridge, because that is the concrete terminal integration point where Supacode receives terminal actions (OSC progress, title/path, mouse/link, size, scrollbar, command status) and forwards user text into the Ghostty PTY surface.

Implemented changes are intentionally reversible and environment-gated:

- `SUPACODE_RENDER_STATS=1` or `SUPACODE_ENERGY_DEBUG=1` enables periodic `render_stats:` summaries through `SupaLogger`.
- `SUPACODE_ENERGY_MODE=1` raises Supacode's existing OSC-9 progress coalescing cadence from 50 ms to 250 ms.
- `SUPACODE_PROGRESS_THROTTLE_MS=<positive integer>` explicitly sets the OSC-9 progress coalescing cadence and overrides energy mode.

### Shipping UI: Low Energy Mode switch

The energy optimization is now exposed as a user-facing setting, not just an env
flag. **Settings → General → Energy → "Low Energy Mode"** persists
`GlobalSettings.lowEnergyModeEnabled` (opt-in, default off) to the settings file.
When on, new terminal surfaces resolve the progress throttle to the 250 ms
energy cadence via `GhosttySurfaceBridge` reading `@Shared(.settingsFile)`.
Precedence (highest first): `SUPACODE_PROGRESS_THROTTLE_MS` env override →
`SUPACODE_ENERGY_MODE` env flag or the persisted Low Energy Mode setting →
default 50 ms. The env vars remain for headless benchmarking; the setting is the
shipping control. The setting applies to terminals opened after the change and
never alters model/agent behavior or drops terminal output.

The optimization does **not** change model/agent execution and does **not** hide or drop terminal output. It only reduces how often repeated progress metadata updates are applied to Supacode's observable tab/progress state. REMOVE still clears immediately.

## Pipeline findings

Concrete hook points found:

1. `GhosttySurfaceView` creates and owns `ghostty_surface_t`, forwards keyboard/mouse/text input, updates size/focus/occlusion, and wraps the surface in `GhosttySurfaceScrollView`.
2. `GhosttySurfaceBridge.handleAction(target:action:)` receives Ghostty app/surface actions and mutates `GhosttySurfaceState` or calls lifecycle callbacks.
3. OSC-9 progress already had a leading-edge/trailing-edge coalescer in `GhosttySurfaceBridge.ingestProgressReport(...)` with a default 50 ms throttle and a 1 s stale-watch cadence.
4. `GhosttySurfaceScrollView.updateScrollbar(...)`, `layout()`, and `GhosttySurfaceView.updateSurfaceSize(...)` are practical app-side proxies for screen/viewport churn. Actual GPU frame commits happen inside GhosttyKit/CAMetal/AppKit and are not directly exposed by the current Swift API.

## What was instrumented

With `SUPACODE_RENDER_STATS=1` or `SUPACODE_ENERGY_DEBUG=1`, Supacode now logs a summary every 5 seconds:

```text
render_stats: interval_s=5.00 actions_per_s=... progress_reports_per_s=... progress_applies_per_s=... progress_removals=... terminal_input_bytes_per_s=... scroll_commits_per_s=... size_updates_per_s=... layout_passes_per_s=...
```

Counters:

- `actions_per_s`: Ghostty actions observed by `GhosttySurfaceBridge`.
- `progress_reports_per_s`: incoming OSC-9 progress reports.
- `progress_applies_per_s`: progress reports that survived coalescing and changed observable state.
- `terminal_input_bytes_per_s`: bytes Supacode sends into the terminal surface from user/app input paths.
- `scroll_commits_per_s`: scrollbar updates from Ghostty into AppKit scroll state; used as an app-side visible-screen churn proxy.
- `size_updates_per_s`: actual Ghostty surface-size changes after backing-size dedupe.
- `layout_passes_per_s`: AppKit wrapper layout passes for the scroll/surface wrapper.

## Verified optimization

The verified optimization is progress/spinner-style metadata throttling behind flags:

- Default remains 50 ms, preserving existing behavior.
- `SUPACODE_ENERGY_MODE=1` changes the default progress throttle to 250 ms (about 4 fps) for progress-only UI churn.
- `SUPACODE_PROGRESS_THROTTLE_MS` allows independent measurement at any positive interval.

Existing test coverage already exercises coalescing correctness: leading edge applies promptly, trailing updates coalesce to the latest value, identical indeterminate floods do not re-apply, stale progress clears, and REMOVE wins immediately. This pass added test cases for the new environment/config behavior; full test execution was blocked by local build prerequisites listed below.

## Benchmark instructions

A helper script writes repeatable local workload scripts and context:

```bash
scripts/energy-benchmark.sh
```

Manual recipe after building:

```bash
# Baseline instrumentation
SUPACODE_RENDER_STATS=1 make run-app 2>&1 | tee docs/energy-logs/baseline-app.log

# Run inside a Supacode terminal pane
docs/energy-logs/spinner-workload.sh
docs/energy-logs/stream-workload.sh

# Energy-mode instrumentation
SUPACODE_RENDER_STATS=1 SUPACODE_ENERGY_MODE=1 make run-app 2>&1 | tee docs/energy-logs/energy-mode-app.log

# Compare internal counters
grep 'render_stats:' docs/energy-logs/*.log
```

Optional CPU sampling while Supacode is running:

```bash
ps -A -o pid,comm | grep -i Supacode
top -pid <PID> -stats pid,cpu,command -l 30 -s 1 | tee docs/energy-logs/top-supacode.log
```

## What is proven vs not proven

Covered by implementation and parse/typecheck verification in this pass:

- Supacode has app-side terminal action/progress/scroll/size/layout instrumentation behind env flags.
- Progress-only update churn can be coalesced without dropping progress state correctness.
- Energy mode is reversible and does not affect model/agent behavior or terminal byte delivery.

### Verified render-commit reduction (Gate 3, deterministic)

The progress/spinner coalescer is now proven quantitatively by a deterministic
`TestClock`-driven test that replays a determinate progress bar animating through
100 distinct values at ~50fps (the Gate 3 spinner-only workload) and counts
committed observable renders (`onProgressReport` applies) vs raw mutations:

| Metric | Raw mutations | Committed renders | Reduction |
| --- | --- | --- | --- |
| Energy mode (250 ms throttle) | 100 | 9 | **91%** |

- `energyModeCoalescesSpinnerBurstByAtLeast70Percent` asserts `reduction >= 0.70`;
  measured **91%**, clearing the Gate 3 ">= 70% reduction in render commits" bar.
- `energyModeCommitsFewerRendersThanDefault` asserts energy mode commits strictly
  fewer renders than the default 50 ms cadence for the identical workload
  (proving the flag buys real headroom, not a relabel).
- Both run headlessly in CI/`make test` with no GUI, no wall-clock flake, and no
  loss of final-value correctness (the bar still tracks to its latest value).

This is a mechanism proof: it measures the observable render-commit stream the
Swift layer controls, which is the app-side lever for GPU frame commits downstream.

Not fully proven in this non-interactive run:

- Actual before/after battery/package-watt delta from `powermetrics` or Instruments
  (requires the GUI app running interactively on a physical display).
- Actual Ghostty renderer frame/commit count, because the Swift integration does
  not expose a render callback or render duration metric.
- End-to-end real-agent CPU improvement under identical live agent tasks.

## Verification from this cron run

Commands executed:

```bash
git diff --check
xcrun swiftc -parse supacode/Infrastructure/Ghostty/GhosttySurfaceBridge.swift supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift supacode/Infrastructure/Ghostty/TerminalEnergyConfiguration.swift supacode/Infrastructure/Ghostty/TerminalEnergyDiagnostics.swift supacodeTests/GhosttySurfaceBridgeTests.swift
xcrun swiftc -typecheck supacode/Infrastructure/Ghostty/TerminalEnergyConfiguration.swift
scripts/energy-benchmark.sh docs/energy-logs
make doctor
make build-app
```

Outcomes:

- `git diff --check`: passed.
- `xcrun swiftc -parse ...`: passed.
- `xcrun swiftc -typecheck TerminalEnergyConfiguration.swift`: passed.
- `scripts/energy-benchmark.sh docs/energy-logs`: passed and printed the baseline/energy-mode measurement recipe.
- `make doctor`: blocked by missing local prerequisites: `mise not installed`, missing submodules `ThirdParty/ghostty ThirdParty/zmx Resources/git-wt`, and no Zig-linkable Xcode (`macOS 26.4+ SDK dropped arm64-macos`; doctor requests Xcode 26.3 / macOS 26.2 SDK).
- `make build-app`: blocked by the same preflight failures before compilation.

## Remaining risks and next work

1. Add GhosttyKit-level render callback/timing if available upstream, or patch the local Ghostty bridge to expose frame commit and render duration counters.
2. Run the provided spinner/stream benchmarks interactively on a Mac with Supacode visible and collect `render_stats`, `top`, and `powermetrics` logs.
3. If progress/app-side churn is confirmed, consider a user-facing setting for energy mode in Settings rather than env-only control.
4. Investigate output-frame coalescing lower in GhosttyKit if high-frequency stdout still produces high GPU frame commits despite app-side progress coalescing.

## Final cumulative E7 status

The final cumulative benchmark did not produce a valid numeric comparison. The plan's `75%` mean CPU goal is unverified and unreached because the focused-visible automation path cannot reliably make the launched development app frontmost in this environment, and `appkit_proxy` counters do not measure true native Metal/Ghostty presents.

### Energy governor commit ledger

| Stage | Commit | Evidence scope |
| --- | --- | --- |
| E0 | `88801615` Add render proof counters | Added appkit-proxy render request/commit/coalescing diagnostics. |
| E0 | `1b41daa8` Add energy workload variants | Added deterministic workload variants. |
| E0 | `652965b6` Add workload metadata to energy benchmark | Added workload/state metadata to benchmark output. |
| E0 | `a421067d` Test energy benchmark proof modes | Added benchmark contract tests. |
| E0 | `38656b9b` Record E0 proof evidence | Recorded proof artifact `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-proof-smoke-e0-20260710013129`. |
| E1 | `b9fa8f76` Cap unfocused terminal render proxies | Added background/unfocused bridge cap. |
| E2 | `fccde3b8` Suspend hidden terminal presentation proxies | Added hidden/minimized presentation suspend. |
| E3 | `f4e1e501` Add idle quiet terminal render governor | Added focused idle quiet bridge governor. |
| E4 | `2f2e3ddf` Add focused Low Energy terminal cap | Added explicit focused Low Energy cap. |
| E4 | `5924984f` Fix energy benchmark report contract | Enforced failed nonnumeric reports when rows are missing. |
| E5 | `ec312535` Add focused default terminal cap | Added default focused bridge cap. |
| E5 | `201cc8ed` Record E5 focused cap notes | Recorded focused cap notes. |
| E5 | `a82d9194` Record E5 benchmark blocker | Recorded focused-visible blocker artifact. |
| E6 | `39e41511` Test OSC-9 progress governor precedence | Added composed governor progress tests. |
| E6 | `c3897cd5` Record E6 progress evidence | Recorded retained calibration and blocked focused-visible evidence. |
| E6 | `db3dbec4` Test OSC-9 stale removal cleanup | Added stale-removal cleanup coverage. |

Earlier branch setup commits that support this evidence are `374376e9`, `48758155`, `c43fa9d0`, `dc1d6451`, `2242143a`, `6ec3ea8c`, `f09990a1`, `95fa5037`, `e8faee21`, and `a613b3bb`.

### Artifact ledger

| Stage | Artifact | Result |
| --- | --- | --- |
| E0 | `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-proof-smoke-e0-20260710013129` | Valid proof rows with `workload`, `state`, and `render_stats_proof=true`. |
| E1 | `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e1-background-progress-smoke-final` | `progress-only` background-unfocused appkit-proxy reduction: `80.97%`. |
| E2 | `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e2-hidden-smoke-final` | Hidden steady committed proxy intervals near `0.99` baseline fps and `0.97` Low Energy fps. |
| E3 | `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e3-idle-spinner-smoke-final` | `spinner-status` appkit-proxy reduction: `0.00%`; native renderer wakeups bypass Swift proxy counters. |
| E4 | `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e4-focused-progress-smoke-contract-postbuild-20260710043019` | Failed nonnumeric focused-visible artifact: header-only CSV, empty JSONL, failed report. |
| E5 | `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e5-focused-progress-smoke-202607100453` | Failed nonnumeric focused-visible artifact: header-only CSV, empty JSONL, failed report. |
| E6 | `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e6-focused-progress-smoke-202607100510` | Failed nonnumeric focused-visible artifact: header-only CSV, empty JSONL, failed report. |
| E7 | `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e7-final-cumulative-focused-visible-20260710052926` | Failed nonnumeric final focused-visible artifact: `summary.csv` header only, `summary.jsonl` empty, `report.md` reports unavailable CPU/proxy metrics. |

### Final verification evidence

Commands run in order on 2026-07-10:

```bash
scripts/test-energy-benchmark.sh
make test
make build-app
```

Outcomes:

- `scripts/test-energy-benchmark.sh`: passed syntax, workload smoke, dry-run, stale-report, unsupported-workload, and render-stats-off checks.
- `make test`: passed `2251` tests in `150` suites with `11` known issues; result bundle `/Users/sethwebster/Library/Developer/Xcode/DerivedData/supacode-cfeclnaplfuzuecakbwrryychanq/Logs/Test/Test-supacode-2026.07.10_05-23-51-+0200.xcresult`.
- `make build-app`: passed and produced the Debug app at `/Users/sethwebster/Library/Developer/Xcode/DerivedData/supacode-cfeclnaplfuzuecakbwrryychanq/Build/Products/Debug/supacode.app`.

### Exact limiting factors

- Focused-visible benchmark automation cannot make the launched development app frontmost before sampling, so E4/E5/E6/E7 focused-visible runs stop before baseline/low-energy rows are written.
- `appkit_proxy` counters cover Swift/AppKit bridge proxy requests and committed proxy frames, not true Metal present frames or native Ghostty renderer thread wakeups.
- E3's spinner workload confirms this limitation: idle quiet state was reached, but appkit-proxy reduction stayed `0.00%` because the workload's native renderer churn is outside the Swift proxy accounting path.
- The machine-readable contract remains strict: no success report is valid without matching baseline and final CSV/JSONL rows for every requested mode and repeat.
