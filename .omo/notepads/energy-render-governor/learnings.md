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
