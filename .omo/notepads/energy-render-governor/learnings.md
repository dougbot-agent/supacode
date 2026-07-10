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
