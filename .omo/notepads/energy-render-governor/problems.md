# Problems

## 2026-07-10 Task: E0 proof infrastructure
- Initial smoke used the pre-change built app and correctly failed missing proof-field validation; reran after `make build-app` into a fresh output directory.
- E0 does not prove real committed Metal frames; later governor loops still need a true present hook or must keep the proxy naming in reports.

## 2026-07-10 Task: E1 background/unfocused cap
- A mixed workload smoke showed only ~50% all-proxy reduction because scroll commits are intentionally immediate bypasses; use `progress-only` for the governable OSC-9 proxy proof and keep mixed as counter-evidence for bypass traffic.
- The benchmark still proves `appkit_proxy` counters, not real Metal presents; the report names the 70% target as appkit proxy frame reduction.

## 2026-07-10 Task: E2 hidden/minimized suspend
- The final hidden smoke summary mean is above 1fps because it averages warmup size/layout and restore/visible intervals with the steady hidden interval; use the per-interval `render-stats.log` lines with `suspend_state=hidden_minimized_or_occluded` as the hidden-state proof.
- The low-energy hidden smoke reported `occlusion_state=visible` while `suspend_state=hidden_minimized_or_occluded`; AppKit AX minimization still engaged the bridge suspend path, but core Ghostty occlusion diagnostics can lag the AppKit minimized signal in headless automation.

## 2026-07-10 Task: E3 adaptive idle quiet governor
- E3 did not meet the focused `spinner-status` benchmark target with current `appkit_proxy` counters: `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e3-idle-spinner-smoke-final/report.md` reported `0.00%` proxy reduction against the 40% target.
- The failed run is still useful evidence: low-energy intervals reported `governor_state=focused_idle_quiet_governor idle_state=idle_quiet`, while `presentation_requests_per_s` stayed around startup/layout/scroll proxy noise instead of the workload's 20Hz spinner churn.
- Safe maximum for this E3 loop is bridge-level idle quiet proxy coalescing; cutting real focused spinner frames requires a later native Ghostty renderer-thread cadence hook, not more Swift bridge accounting.

## 2026-07-10 Task: E4 focused Low Energy cap
- The final post-build benchmark retries timed out while applying `focused-visible` because System Events lost assistive access (`osascript` error -25211); the earlier E4 focused `progress-only` artifact remains the benchmark proof for appkit proxy counters, and final code/test/build gates passed after the diagnostic-only change.
- Long focused workloads usually enter E3 `focused_idle_quiet_governor` before the 5s render_stats summary, so E4 adds deduped governor transition logs to expose the initial `focused_low_energy_cap` state before idle quiet takes precedence.

## 2026-07-10 Task: E4 summary/report contract correction
- The old E4 `supacode-energy-e4-focused-progress-smoke-final` artifact must not be used as passing evidence because its machine-readable rows are missing.
- Two fresh focused-visible E4 attempts remained blocked at `timed out waiting for launched dev app window to become frontmost`; the corrected harness now reports that as failed evidence, so E4 remains unchecked until a GUI-capable run produces baseline and low-energy rows.

## 2026-07-10 Task: E5 focused default cap
- Fresh E5 focused-visible attempt `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e5-focused-progress-smoke-202607100453` remained blocked before workload sampling at `timed out waiting for launched dev app window to become frontmost`.
- The blocked E5 artifact is intentionally non-numeric: `summary.csv` contains only the header, `summary.jsonl` is empty, and `report.md` says `Status: failed` with unavailable appkit proxy metrics.
- Safe maximum for this E5 verification loop is unit/script/build proof plus a preserved failed GUI artifact until System Events assistive/window control can make the launched dev app frontmost.

## 2026-07-10 Task: E6 OSC-9 progress throttle calibration and retention
- Fresh E6 focused-visible progress-only attempt `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e6-focused-progress-smoke-202607100510` remained blocked at `timed out waiting for launched dev app window to become frontmost` before workload sampling.
- The E6 blocked artifact preserves the E4/E5 report contract: `summary.csv` is header-only, `summary.jsonl` is empty, and `report.md` reports `Status: failed` with unavailable appkit proxy metrics.

## 2026-07-10 Task: E7 final cumulative benchmark and report
- The final E7 focused-visible run remained blocked before workload sampling at `timed out waiting for launched dev app window to become frontmost`; no baseline/low-energy rows were written.
- The blocker is external to governor logic: System Events/AppKit automation cannot reliably make the launched development app frontmost in this environment, so focused-visible E4/E5/E6/E7 benchmark evidence must stay `[~]` until a GUI-capable run can sample both modes.
- The wrapper command that launched the E7 attempt also hit zsh's read-only `status` variable while printing the exit code, but the benchmark artifact itself was already written and preserves the failed nonnumeric report contract.

## 2026-07-10 Task: focused-visible non-System-Events discovery
- No tested non-System-Events mechanism can currently make the launched app frontmost in this session: `NSRunningApplication.activate` returned `false`, and app-owned `surfaceMainWindow()` via `supacode open` did not change the frontmost application.
- The current frontmost application during probes was `com.apple.loginwindow`, which means this session lacks an interactive foreground GUI context even when the debug app process and socket exist.
- The safe conclusion remains an external focused-visible automation blocker; clearing E4/E5/E6/E7 requires a user environment with an interactive GUI session or authorized automation that can actually make the benchmark app frontmost.

## 2026-07-10 Task: focused-visible retry after user request
- Focused-visible activation is no longer the current blocker in this retry: both progress-only and full mixed E7 runs completed with matching CSV/JSONL rows.
- The fresh progress-only retry does not prove the `75%` CPU goal because Low Energy CPU was slightly higher than baseline (`-0.42%` reduction), even though `appkit_proxy` frame reduction was `85.83%`.
- The fresh full E7 mixed retry remains below targets: CPU reduction was `1.66%` and mean `appkit_proxy` frame reduction was `46.85%`, so the cumulative `75%` CPU target remains failed rather than merely blocked.

## 2026-07-10 Task: immediate focused-visible retry
- The immediate progress-only focused-visible retry completed, so frontmost activation was not the blocker for this attempt.
- The immediate retry still does not prove the `75%` CPU goal because Low Energy CPU was higher than baseline (`-1.09%` CPU reduction), even though `appkit_proxy` frame reduction was `85.53%`.

## 2026-07-10 Task: final safe-maximum disposition
- E4 is no longer blocked by focused-visible activation, but the valid direct comparison fails: CPU reduction `-6.87%` and direct committed `appkit_proxy` reduction `10.47%`, below the `50%` target.
- E5 is not meaningfully exercised because the default focused cap is about `30fps`, while the observed baseline committed proxy rate is only `10.9329/s`.
- E7 safe maximum failed on valid evidence: CPU reduction `1.66%` against the `75%` goal, and mixed proxy-vs-request reduction `46.85%` against the mixed `70%` proxy target.
