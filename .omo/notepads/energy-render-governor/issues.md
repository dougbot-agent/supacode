# Issues

## 2026-07-09 Task: start-work-init
- Dirty worktree exists before energy governor work: `supacode/Clients/Zmx/ZmxClient.swift`, `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`, `supacodeTests/ZmxClientTests.swift`, and `.omo/`.

## 2026-07-10 Task: E7 final cumulative benchmark and report
- Focused-visible GUI automation remains blocked by inability to make the launched dev app frontmost, so the final cumulative `75%` mean CPU target is unverified/unreached and must not be marked successful without fresh complete CSV/JSONL rows.

## 2026-07-10 Task: focused-visible non-System-Events discovery
- Public AppKit activation and the existing `supacode open` socket command both failed to make the debug app frontmost in this session; E4-E7 focused-visible rows remain externally blocked.

## 2026-07-10 Task: focused-visible retry after user request
- Fresh focused-visible rows now exist, but E7 still fails on results: full mixed CPU reduction is `1.66%` and mean `appkit_proxy` frame reduction is `46.85%`, below the `75%` CPU and `70%` mixed appkit-proxy targets.

## 2026-07-10 Task: immediate focused-visible retry
- Fresh immediate progress-only rows exist and pass the `50%` appkit-proxy target, but the CPU result is `-1.09%` and therefore cannot satisfy the cumulative `75%` CPU goal.

## 2026-07-10 Task: final safe-maximum disposition
- The final safe wrapper-level result is a measured failure, not an activation blocker: E4 direct CPU `-6.87%`, E4 direct committed `appkit_proxy` reduction `10.47%`, and E7 CPU reduction `1.66%`.
- Native Metal/Ghostty present frames remain unmeasured by `appkit_proxy`; further improvement needs a native renderer/present hook rather than more Swift wrapper iteration.
