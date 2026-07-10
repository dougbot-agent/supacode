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
