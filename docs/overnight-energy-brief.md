# Overnight Task Brief: Reduce Supacode Terminal/TUI Battery Drain

## Mission
Reduce Supacode terminal/TUI battery drain by proving whether avoidable rendering, repainting, polling, and update churn contribute meaningfully to high energy usage during focused terminal/TUI use, then implement at least one verified optimization behind flags without degrading correctness or interactivity.

## Problem Description
Supacode appears to cause unusually high energy usage on macOS during focused terminal/TUI use. Similar behavior has been observed across Supacode, cmux/tmux-style panes, Warp, and iTerm2, suggesting the issue may not be only the terminal emulator.

Likely contributors:

- Excessive TUI redraws.
- High-frequency stdout/stderr writes.
- Spinner/progress animations.
- Streaming token updates.
- Polling loops.
- Background agent work.

Hypothesis: Supacode’s terminal UI performs unnecessary visual work while focused, causing elevated CPU/GPU wakeups and preventing Apple Silicon from entering low-power idle states.

Goal: do not make the agent do less useful work. Prove whether Supacode can reduce battery/energy usage by reducing avoidable rendering, repainting, polling, and update churn without degrading interactivity.

Core mental model:

```text
PTY / agent events = high-frequency mutations
TUI state = retained screen model
visible terminal frame = throttled committed render
```

Supacode should behave more like a retained UI system: accept every event, preserve correctness, but commit visual frames only when useful.

## Testable Solutions
Implement behind flags so each optimization can be measured independently.

### A. Render instrumentation
Add counters/timings for:

- renders per second
- screen commits per second
- bytes written to terminal per second
- number of full-screen redraws
- number of partial redraws
- average render duration
- max render duration
- event-loop wakeups per second, if observable
- CPU time by process
- idle CPU usage while agent is waiting
- focused streaming CPU usage
- spinner/progress-only CPU usage

Expose via:

```bash
SUPACODE_RENDER_STATS=1
SUPACODE_ENERGY_DEBUG=1
```

Log periodic summaries in a reproducible format, e.g.:

```text
render_stats: fps=42 commits=126 full_redraws=38 bytes=4.2MB avg_render_ms=5.8
```

### B. Frame coalescing
Introduce a render scheduler.

Instead of rendering immediately on every state mutation:

```text
mutation → mark dirty → schedule frame → render latest state
```

Modes:

- interactive input: immediate or <= 16ms
- normal focused output: max 30 fps
- LLM streaming: max 10–20 fps
- spinner/progress-only: max 2–4 fps
- background/unfocused pane: max 1 fps or render-on-focus

Config:

```bash
SUPACODE_MAX_FPS=20
SUPACODE_STREAM_FPS=12
SUPACODE_SPINNER_FPS=4
```

### C. Spinner/progress throttling
Detect repeated writes that update the same line or visual region without adding meaningful content, e.g.:

```text
| Thinking
/ Thinking
- Thinking
\ Thinking
```

Only commit the latest visual state at a low rate. Acceptance target: spinner-only mode should consume near-idle CPU.

### D. Streaming-token batching
During LLM streaming, buffer token output for 50–100ms before rendering. Do not drop content; only batch visual commits.

Config:

```bash
SUPACODE_STREAM_BATCH_MS=75
```

Expected behavior:

- text still appears live
- no perceptible interaction regression
- much lower render frequency

### E. Partial redraw / dirty-region rendering
Audit whether Supacode redraws the whole viewport too often. Implement or improve dirty-region rendering:

- only repaint changed rows
- avoid re-layout of unchanged panes
- avoid re-rendering stable markdown blocks
- avoid recalculating visible scrollback unless viewport changed

### F. Offscreen and background pane sleep
If Supacode has panes, tabs, logs, hidden panels, or scrollback views:

- do not render hidden panes
- do not syntax-highlight offscreen output immediately
- do not reflow scrollback unless needed
- defer expensive formatting until content becomes visible

### G. Idle-loop audit
Search for loops like:

- `setInterval(...)`
- `setTimeout(...)`
- `while (...)`
- `requestAnimationFrame(...)`

Classify each as:

- required
- can be event-driven
- can be slowed
- can sleep when idle
- can stop when pane hidden

Replace polling with event-driven updates where possible.

### H. Energy mode
Add a user-facing setting:

```bash
supacode --energy-mode
```

or config:

```json
{
  "energyMode": true,
  "maxFps": 20,
  "streamFps": 12,
  "spinnerFps": 4,
  "backgroundPaneFps": 1,
  "deferOffscreenRendering": true
}
```

Energy mode must preserve correctness. It may reduce animation smoothness.

## Benchmark Plan
Create repeatable benchmark scenarios.

1. **Idle focused Supacode**
   - Open Supacode, focus terminal, no agent work.
   - Measure for 5 minutes.

2. **Spinner-only workload**
   - Run a fake task that updates the same line at 30–60 fps.
   - Expected improvement: huge reduction in commits and CPU.

3. **LLM streaming simulation**
   - Replay a captured token stream at realistic speed.
   - Compare baseline immediate rendering, 100ms batching, and 12 fps capped rendering.

4. **Large output burst**
   - Replay large command output: `find .`, `cat large.log`, `rg something`.
   - Expected improvement: fewer intermediate frames, final viewport correct.

5. **Real Supacode agent session**
   - Run a representative coding-agent task in the same repo before/after.
   - Measure energy impact without relying only on synthetic tests.

## Measurement Tools
Use macOS tools where possible:

- `powermetrics`
- `top`
- `ps`
- `sample`
- `spindump`
- Activity Monitor Energy tab
- Instruments: Time Profiler
- Instruments: Energy Log

Also capture Supacode internal metrics.

Minimum report should include:

- baseline CPU %
- optimized CPU %
- baseline renders/sec
- optimized renders/sec
- baseline terminal bytes/sec
- optimized terminal bytes/sec
- baseline avg render ms
- optimized avg render ms
- baseline powermetrics package watts, if available
- optimized package watts, if available

## Exit Gates: Verification and Proof
The task is not complete until there is proof.

### Gate 1: Instrumentation exists
Pass condition:

- Supacode can print render/commit stats.
- Stats work in idle, streaming, spinner, and real-agent scenarios.
- Logs are saved in a reproducible format.

Proof required:

- `before.log`
- `after.log`
- benchmark command used
- machine model
- macOS version
- Supacode commit SHA

### Gate 2: Focused idle regression is zero or improved
Pass condition:

- Focused idle CPU is not worse than baseline.
- Render commits approach zero when no visible state changes.

Proof required:

- 5-minute idle baseline
- 5-minute idle optimized
- CPU and render stats

### Gate 3: Spinner/progress updates are throttled
Pass condition:

- Spinner/progress-only UI renders at configured low FPS.
- No content correctness loss.
- CPU drops meaningfully versus baseline.

Targets:

- >= 70% reduction in render commits
- >= 30% reduction in CPU for spinner-only benchmark

### Gate 4: Streaming output is batched
Pass condition:

- LLM/token streaming remains readable.
- Text order is correct.
- No tokens are dropped.
- Render commits drop significantly.

Targets:

- >= 50% reduction in render commits during stream replay
- >= 20% reduction in CPU during stream replay

### Gate 5: Large output burst does not render useless intermediate states
Pass condition:

- Final viewport is correct.
- Scrollback is correct.
- Intermediate render commits are reduced.

Target:

- >= 50% reduction in render commits during large-output benchmark

### Gate 6: Real-world Supacode session improves
Pass condition:

- Run the same representative agent task before and after.

Targets:

- >= 15% reduction in average CPU or package energy
- no correctness regressions
- no unacceptable perceived latency

### Gate 7: Flagged, documented, and reversible
Pass condition:

- All changes are behind config/flags.
- Default behavior is either unchanged or intentionally documented.
- User can disable energy optimizations.
- README includes benchmark instructions.

### Gate 8: Final proof package
Produce a final report containing:

- summary of findings
- root causes confirmed
- root causes disproven
- optimizations implemented
- before/after tables
- benchmark commands
- logs
- screenshots or terminal captures if useful
- remaining risks
- recommended next work

## Non-Goals
- Do not optimize by hiding real output.
- Do not skip agent work.
- Do not change model behavior.
- Do not make the TUI feel broken.
- Do not rely on subjective “feels better” claims without measurements.

## Definition of Done
The fork proves, with repeatable measurements, whether Supacode’s focused terminal/TUI rendering contributes meaningfully to battery drain, and implements at least one verified optimization that reduces redraws, CPU, or energy usage while preserving correctness.
