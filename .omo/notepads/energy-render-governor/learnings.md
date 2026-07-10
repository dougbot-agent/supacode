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
