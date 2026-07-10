# Decisions

## 2026-07-09 Task: start-work-init
- E0 proof infrastructure must complete before energy optimizations. Otherwise later benchmark wins can be false positives.
- Use task subagents for all product code/test/script edits. Atlas edits only `.omo` state and verifies.

## 2026-07-10 Task: E4 focused Low Energy cap
- Choose 100ms (10fps) for the focused Low Energy cap because it is inside the requested 10-15fps band and gives a measurable 50% theoretical reduction against the default 50ms focused bridge cadence while leaving E3 idle quiet at 250ms.
- Keep the cap optional and named separately from background/idle caps so E5 can add a default focused cap later without changing Low Energy selection semantics.

## 2026-07-10 Task: E4 summary/report contract correction
- Treat missing CSV/JSONL machine-readable rows as a hard benchmark failure even if a report file exists.
- A successful numeric report is valid only after `summary.csv` and `summary.jsonl` contain the expected row count for every requested mode and repeat.

## 2026-07-10 Task: E5 focused default cap
- Choose 33ms for the normal focused cap because it is the conservative integer cadence closest to 30fps and stays weaker than Low Energy's existing 100ms focused cap.
- Keep E5 in the existing bridge cadence selector instead of adding another scheduler: hidden suspend, unfocused/background cap, idle quiet, focused cap, then base throttle.

## 2026-07-10 Task: E6 OSC-9 progress throttle calibration and retention
- Retain `defaultProgressThrottleMs=50`, `defaultFocusedFrameCapMs=33`, and `energyModeFocusedFrameCapMs=100` because E6 produced deterministic correctness evidence but no successful numeric focused-visible benchmark rows; changing cadence without a valid counter win would be speculative.
