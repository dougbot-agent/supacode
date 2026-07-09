# Learnings

## 2026-07-09 Task: start-work-init
- Plan normalized with top-level checkboxes because auto-start reported 0/0 tasks.
- Current branch has pre-existing unrelated dirty product files; workers must not touch/stage them.

## 2026-07-10 Task: E0 proof infrastructure
- No app-wrapper Metal presentation hook is exposed yet, so E0 counters are named `appkit_proxy`: OSC-9/layout/scroll/size requests, committed-frame proxies, and coalesced progress proxies.
- Fresh smoke artifact: `/var/folders/db/wnztnt0d0zb87jdhxp6t_vc80000gn/T/supacode-energy-proof-smoke-e0-20260710013129`; `summary.jsonl` includes `workload`, `state`, and `render_stats_proof=true`.
- Deterministic workload modes now cover `mixed`, `progress-only`, `spinner-status`, and `stream-only`; unsupported workloads fail before GUI launch.
