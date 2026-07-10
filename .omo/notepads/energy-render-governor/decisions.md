# Decisions

## 2026-07-09 Task: start-work-init
- E0 proof infrastructure must complete before energy optimizations. Otherwise later benchmark wins can be false positives.
- Use task subagents for all product code/test/script edits. Atlas edits only `.omo` state and verifies.

## 2026-07-10 Task: E4 focused Low Energy cap
- Choose 100ms (10fps) for the focused Low Energy cap because it is inside the requested 10-15fps band and gives a measurable 50% theoretical reduction against the default 50ms focused bridge cadence while leaving E3 idle quiet at 250ms.
- Keep the cap optional and named separately from background/idle caps so E5 can add a default focused cap later without changing Low Energy selection semantics.
