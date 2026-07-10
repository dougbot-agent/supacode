# Learnings

## 2026-07-09 Task: start-work-init
- Plan normalized with top-level checkboxes because auto-start reported 0/0 tasks.
- Current branch has pre-existing unrelated dirty product files; workers must not touch/stage them.

## 2026-07-10 Task: E0 proof infrastructure
- No app-wrapper Metal presentation hook is exposed yet, so E0 counters are named `appkit_proxy`: OSC-9/layout/scroll/size requests, committed-frame proxies, and coalesced progress proxies.
- Fresh smoke artifact: `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-proof-smoke-e0-20260710013129`; `summary.jsonl` includes `workload`, `state`, and `render_stats_proof=true`.
- Deterministic workload modes now cover `mixed`, `progress-only`, `spinner-status`, and `stream-only`; unsupported workloads fail before GUI launch.

## 2026-07-10 Task: E1 background/unfocused cap
- E1 keeps E0 `appkit_proxy` naming and reports active cap diagnostics as `governor_state=background_unfocused_cap cap_state=active cap_fps=4.00` while the app/window is unfocused or backgrounded.
- Final smoke artifact: `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e1-background-progress-smoke-final`; `progress-only` background-unfocused averaged `80.97%` committed-frame proxy reduction vs presentation requests.
- App/window active-key notifications now feed the same surface focus path because activating another app does not always make AppKit call `resignFirstResponder()` on the terminal surface.

## 2026-07-10 Task: E2 hidden/minimized suspend
- E2 adds a higher-precedence `hidden_presentation_suspend` / `suspend_state=hidden_minimized_or_occluded` path above the E1 background-unfocused cap; hidden progress reports remain live but governable progress applies are held until visible restore or an immediate bypass.
- Surface visibility now combines Worktree tab/split/window visibility with direct AppKit window visibility (`isVisible`, `isMiniaturized`, occlusion state, hidden ancestor) before calling Ghostty core occlusion and bridge presentation suspension.
- Final hidden smoke artifact: `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e2-hidden-smoke-final`; steady hidden intervals reported `committed_frame_proxies_per_s=0.99` baseline and `0.97` low-energy with `suspend_state=hidden_minimized_or_occluded`.

## 2026-07-10 Task: E3 adaptive idle quiet governor
- E3 adds a focused idle quiet state for bridge-level render proxy requests: `SUPACODE_ENERGY_MODE=1` enables `idle_quiet_threshold_ms=500` and `idle_quiet_frame_cap_ms=250`, while baseline keeps focused passthrough.
- Unit coverage proves no quiet mode before the idle threshold, quiet coalescing after the threshold, immediate interaction exit/flush, and E2/E1 precedence over idle quiet.
- Focused `spinner-status` runtime evidence entered `focused_idle_quiet_governor`, but the workload did not emit high-frequency Swift bridge render proxy requests; native Ghostty renderer wakeups bypass the current `appkit_proxy` counter path.

## 2026-07-10 Task: E4 focused Low Energy cap
- E4 makes the Low Energy Mode focused interactive bridge cap explicit at `focused_low_energy_frame_cap_ms=100` (10fps) through the same persisted setting / `SUPACODE_ENERGY_MODE=1` gate; `SUPACODE_PROGRESS_THROTTLE_MS` still carries the focused cap for benchmark overrides unless `SUPACODE_FOCUSED_FRAME_CAP_MS` is set.
- Focused Low Energy is a lower-precedence bridge cadence than hidden suspend, background/unfocused cap, and E3 idle quiet; TestClock coverage proves focused cadence, setting/env convergence, interaction flush, and idle quiet precedence.
- Focused `progress-only` evidence artifact: `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e4-focused-progress-smoke-final`; report shows `79.64%` mean appkit proxy frame reduction vs requests and passes the E4 50% appkit proxy target.

## 2026-07-10 Task: E4 summary/report contract correction
- Atlas found the prior E4 artifact was invalid: `summary.csv` had only the header and `summary.jsonl` was empty while `report.md` retained numeric pass values from an earlier run.
- The benchmark harness now removes stale reports before each run, writes an explicit failed report on nonzero exits after output initialization, and validates expected CSV/JSONL row counts before writing any numeric success report.
- Fresh blocked artifact `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e4-focused-progress-smoke-contract-postbuild-20260710043019` correctly has header-only CSV, empty JSONL, and `Status: failed` with unavailable metrics instead of a fabricated pass.

## 2026-07-10 Task: E5 focused default cap
- E5 adds a normal focused bridge cap at `focused_default_frame_cap_ms=33` (`governor_state=focused_default_cap`, `cap_fps=30.30`) while keeping Low Energy at `focused_low_energy_cap` / 100ms and idle quiet at 250ms above both focused caps.
- `SUPACODE_PROGRESS_THROTTLE_MS` and `SUPACODE_FOCUSED_FRAME_CAP_MS` remain explicit benchmark overrides and report as `focused_custom_cap`; default `progress_throttle_ms` stays 50ms so the focused cap is selected by bridge cadence precedence instead of relabeling the base progress throttle.
- Prompt-title actions now flush pending bridge work like input, resize, scroll, focus regain, command finish, and bell paths, so prompt-ready UI does not wait behind the focused cap.

## 2026-07-10 Task: E6 OSC-9 progress throttle calibration and retention
- E6 retained the existing OSC-9 throttle/focused-cap values because deterministic tests found correct coalescing under the composed governors and the focused-visible GUI benchmark remained blocked before sampling, so there was no safe measurable improvement signal to justify calibration.
- Added TestClock coverage for progress-specific REMOVE across hidden suspend, unfocused cap, idle quiet, focused Low Energy cap, and focused default cap, plus progress updates proving idle quiet cadence outranks focused caps for OSC-9 paths.
- Required gates passed in order: `scripts/test-energy-benchmark.sh`, `make test` (`2250` tests, `11` known issues), and `make build-app`.

## 2026-07-10 Task: E7 final cumulative benchmark and report
- E7 required gates passed in order: `scripts/test-energy-benchmark.sh`, `make test` (`2251` tests, `11` known issues), and `make build-app`.
- Fresh final focused-visible artifact `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e7-final-cumulative-focused-visible-20260710052926` preserves the machine-readable failure contract: `summary.csv` has only the header, `summary.jsonl` is empty, and `report.md` says `Status: failed` with unavailable CPU/proxy metrics.
- Safe maximum cumulative evidence remains state-specific: E1 background progress-only `80.97%` appkit-proxy reduction, E2 hidden steady intervals near `0.99/0.97 fps`, and E3 spinner `0.00%` appkit-proxy reduction because native Ghostty wakeups bypass Swift proxy counters.

## 2026-07-10 Task: focused-visible non-System-Events discovery
- Existing repo-local `supacode open` is the only app-owned focus path found; it dispatches `supacode://` to `.open`, which calls `NSApplication.shared.surfaceMainWindow()` inside the app.
- External public AppKit activation was tested with `NSRunningApplication(processIdentifier:).activate(options: [.activateAllWindows])`; the target debug app resolved as `bundle=app.supabit.supacode`, but activation returned `false` and `NSWorkspace.shared.frontmostApplication` remained `com.apple.loginwindow`.
- Repo-local socket surfacing was tested with `SUPACODE_SOCKET_PATH=/tmp/supacode-501/pid-10350 supacode open --timeout 3`; it completed without CLI error, but `NSWorkspace.shared.frontmostApplication` still reported `frontmost_pid=178 bundle=com.apple.loginwindow` and the target app stayed inactive.
- Fresh blocked artifact `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-focused-visible-safe-discovery-20260710053840` again has header-only `summary.csv`, empty `summary.jsonl`, and failed `report.md` after timing out at `launched dev app window to become frontmost`.

## 2026-07-10 Task: F2 cadence retiming fix
- Pending progress and render-proxy trailing flush tasks now cancel/re-arm when focus drops or idle quiet starts, so older focused deadlines cannot commit pending work before the stricter unfocused or idle-quiet cadence.
- Deterministic TestClock coverage proves progress and render-proxy pending work stays at the old applied value/count through the prior faster deadline, then commits the latest pending state at the new cadence.
- Focused GhosttySurfaceBridge suite passed with `72` tests via pinned `DEVELOPER_DIR` Xcode path; `scripts/test-energy-benchmark.sh` passed non-GUI syntax/workload/dry-run checks.

## 2026-07-10 Task: focused-visible retry after user request
- Fresh progress-only focused-visible artifact `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e4-e7-focused-progress-retry-20260710063645` has complete machine-readable rows: `summary.csv` has `2` data rows and `summary.jsonl` has `2` rows, one `baseline` and one `low-energy` in each file.
- Focused-visible activation succeeded for the progress-only retry: the harness passed `activate_started_app` for both modes, run PIDs were `89986` and `1580`, and the observable post-run frontmost app was `pid=50602 bundle=app.supabit.supacode name=supacode`.
- Progress-only focused-visible result: baseline CPU `18.9667`, Low Energy CPU `19.0458`, CPU reduction `-0.42%`; mean `appkit_proxy` frame reduction vs requests `85.83%`, passing the `50%` appkit-proxy target while still not proving native Metal/Ghostty presents.
- Full E7 mixed focused-visible artifact `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e7-cumulative-focused-visible-retry-20260710063838` has complete machine-readable rows: `summary.csv` has `6` data rows and `summary.jsonl` has `6` rows, three `baseline` and three `low-energy` in each file.
- Full E7 mixed result: baseline CPU `21.2625`, Low Energy CPU `20.9089`, CPU reduction `1.66%`; mean `appkit_proxy` frame reduction vs requests `46.85%`, failing both the `75%` CPU target and the mixed `70%` appkit-proxy target.

## 2026-07-10 Task: immediate focused-visible retry
- Fresh immediate progress-only focused-visible artifact `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-focused-visible-immediate-retry-20260710065012` has complete machine-readable rows: `summary.csv` has `2` data rows and `summary.jsonl` has `2` rows, one `baseline` and one `low-energy` in each file.
- Focused-visible activation succeeded for the immediate retry: the harness passed `activate_started_app` for both modes, run PIDs were `59623` and `68150`, and the observable post-run frontmost app was `pid=50602 bundle=app.supabit.supacode name=supacode`.
- Immediate progress-only result: baseline CPU `18.7667`, Low Energy CPU `18.9708`, CPU reduction `-1.09%`; mean `appkit_proxy` frame reduction vs requests `85.53%`, passing the `50%` progress-only appkit-proxy target while still not proving native Metal/Ghostty presents.

## 2026-07-10 Task: final safe-maximum disposition
- Direct E4 artifact `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e4-focused-visible-direct-20260710085455` is valid focused-visible evidence: CPU reduction `-6.87%`, direct committed `appkit_proxy` reduction `10.47%`, baseline committed proxy rate `10.9329/s`, Low Energy committed proxy rate `9.7884/s`.
- The direct E4 comparison is Low Energy vs baseline committed proxy rate, while E7's `46.85%` number is proxy-vs-request reduction inside the mixed run; neither is a native Metal or Ghostty present count.
- Valid E7 artifact `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-e7-cumulative-focused-visible-retry-20260710063838` remains failed at the safe maximum: CPU reduction `1.66%` and mixed proxy-vs-request reduction `46.85%`.
- Commits `046430ee` and `728b7427` are part of the final evidence chain for direct benchmark deltas and cadence retiming.
