import AppKit
import Foundation
import GhosttyKit
import Sharing
import SupacodeSettingsShared

private let terminalStateLogger = SupaLogger("Terminal")

enum GhosttyOpenURLKind: Equatable {
  case unknown
  case text
  case html

  init(_ value: ghostty_action_open_url_kind_e) {
    switch value {
    case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT:
      self = .text
    case GHOSTTY_ACTION_OPEN_URL_KIND_HTML:
      self = .html
    default:
      self = .unknown
    }
  }
}

struct GhosttyOpenURLRequest: Equatable {
  let kind: GhosttyOpenURLKind
  let url: URL
}

func ghosttyOpenURLRequest(
  urlString: String?,
  kind: ghostty_action_open_url_kind_e
) -> GhosttyOpenURLRequest? {
  guard let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
    !urlString.isEmpty
  else { return nil }
  let url: URL
  if let candidate = URL(string: urlString), candidate.scheme != nil {
    url = candidate
  } else {
    let expanded = NSString(string: urlString).expandingTildeInPath
    url = URL(filePath: expanded).standardizedFileURL
  }
  return GhosttyOpenURLRequest(kind: GhosttyOpenURLKind(kind), url: url)
}

@MainActor
final class GhosttySurfaceBridge {
  let state = GhosttySurfaceState()
  var surface: ghostty_surface_t?
  weak var surfaceView: GhosttySurfaceView?
  var onTitleChange: ((String) -> Void)?
  var onPromptTitle: (() -> Void)?
  var onSplitAction: ((GhosttySplitAction) -> Bool)?
  var onCloseRequest: ((Bool) -> Void)?
  var onNewTab: (() -> Bool)?
  var onCloseTab: ((ghostty_action_close_tab_mode_e) -> Bool)?
  var onGotoTab: ((ghostty_action_goto_tab_e) -> Bool)?
  var onMoveTab: ((ghostty_action_move_tab_s) -> Bool)?
  var onCommandPaletteToggle: (() -> Bool)?
  var onProgressReport: ((ghostty_action_progress_report_state_e) -> Void)?
  // Fired on OSC 11 background changes only; used to re-tint window chrome
  // when the focused surface's background changes.
  var onColorChanged: (() -> Void)?
  // Used by blocking script completion detection in WorktreeTerminalState.
  // Both callbacks are set on every surface but guarded by the
  // blockingScripts dict in the handlers.
  var onCommandFinished: ((Int?) -> Void)?
  var onChildExited: ((UInt32) -> Void)?
  // The agent's own OSC 9 desktop notification. Deduped against our richer custom
  // notification one layer up.
  var onDesktopNotification: ((String, String) -> Void)?
  // OSC 3008 context signal: (action 0=start/1=end, context id, raw key=value
  // metadata). Forwarded raw; the per-surface capability token carried in the
  // metadata is verified one layer up where the surface's nonce lives.
  var onContextSignal: ((UInt8, String, String) -> Void)?

  // Coalesce OSC-9 progress: a flush task applies the latest value at the
  // throttle cadence while it moves, and a slow stale-watch clears a bar whose
  // reports stopped without a REMOVE.
  private let clock: any Clock<Duration>
  private let progressThrottleInterval: Duration
  private let focusedFrameCapInterval: Duration?
  private let focusedFrameCapMilliseconds: Int?
  private let focusedFrameCapState: TerminalFocusedFrameCapState
  private let unfocusedFrameCapInterval: Duration
  private let unfocusedFrameCapMilliseconds: Int
  private let idleQuietEnabled: Bool
  private let idleQuietThreshold: Duration
  private let idleQuietFrameCapInterval: Duration
  private let idleQuietThresholdMilliseconds: Int
  private let idleQuietFrameCapMilliseconds: Int?
  private let progressIdleInterval: Duration
  private let progressStaleTimeout: Duration
  private var pendingProgress: ProgressUpdate?
  private var appliedProgress: ProgressUpdate?
  private var pendingRenderProxy = false
  private var progressReportCount = 0
  private var progressFlushTask: Task<Void, Never>?
  private var progressStaleTask: Task<Void, Never>?
  private var renderProxyFlushTask: Task<Void, Never>?
  private var idleQuietTask: Task<Void, Never>?
  private var focused = true
  private var presentationSuspendState = TerminalPresentationSuspendState.visible
  private var idleQuietState = TerminalIdleQuietState.inactive
  var onRenderProxyCommit: (() -> Void)?
  var idleQuietStateForTesting: TerminalIdleQuietState { idleQuietState }

  init(
    clock: any Clock<Duration> = ContinuousClock(),
    progressThrottleInterval: Duration? = nil,
    focusedFrameCapInterval: Duration? = nil,
    unfocusedFrameCapInterval: Duration? = nil,
    idleQuietThreshold: Duration? = nil,
    idleQuietFrameCapInterval: Duration? = nil,
    progressIdleInterval: Duration = .seconds(1),
    progressStaleTimeout: Duration = .seconds(15)
  ) {
    self.clock = clock
    // When no explicit interval is injected (production), resolve the throttle
    // from the persisted Low Energy Mode setting (falling back to env overrides
    // for headless benchmarking). Tests inject an explicit interval and never
    // touch shared state, so they stay deterministic.
    if let progressThrottleInterval {
      self.progressThrottleInterval = progressThrottleInterval
    } else {
      let progressThrottleMilliseconds = Self.resolvedProgressThrottleMilliseconds()
      self.progressThrottleInterval = .milliseconds(progressThrottleMilliseconds)
      TerminalEnergyDiagnostics.shared.recordConfiguredProgressThrottle(
        milliseconds: progressThrottleMilliseconds
      )
    }
    if let focusedFrameCapInterval {
      self.focusedFrameCapInterval = focusedFrameCapInterval
      self.focusedFrameCapMilliseconds = Self.durationMilliseconds(focusedFrameCapInterval)
      self.focusedFrameCapState = .custom
    } else {
      @Shared(.settingsFile) var settingsFile
      let capMilliseconds = TerminalEnergyConfiguration.focusedFrameCapMilliseconds(
        lowEnergyModeSetting: settingsFile.global.lowEnergyModeEnabled
      )
      self.focusedFrameCapInterval = capMilliseconds.map { .milliseconds($0) }
      self.focusedFrameCapMilliseconds = capMilliseconds
      self.focusedFrameCapState = TerminalEnergyConfiguration.focusedFrameCapState(
        lowEnergyModeSetting: settingsFile.global.lowEnergyModeEnabled
      )
    }
    if let unfocusedFrameCapInterval {
      self.unfocusedFrameCapInterval = unfocusedFrameCapInterval
      self.unfocusedFrameCapMilliseconds = Self.durationMilliseconds(unfocusedFrameCapInterval)
    } else {
      let capMilliseconds = TerminalEnergyConfiguration.unfocusedFrameCapMilliseconds()
      self.unfocusedFrameCapInterval = .milliseconds(capMilliseconds)
      self.unfocusedFrameCapMilliseconds = capMilliseconds
    }
    if let idleQuietThreshold {
      self.idleQuietThreshold = idleQuietThreshold
      self.idleQuietThresholdMilliseconds = Self.durationMilliseconds(idleQuietThreshold)
    } else {
      let thresholdMilliseconds = TerminalEnergyConfiguration.idleQuietThresholdMilliseconds()
      self.idleQuietThreshold = .milliseconds(thresholdMilliseconds)
      self.idleQuietThresholdMilliseconds = thresholdMilliseconds
    }
    if let idleQuietFrameCapInterval {
      self.idleQuietFrameCapInterval = idleQuietFrameCapInterval
      self.idleQuietFrameCapMilliseconds = Self.durationMilliseconds(idleQuietFrameCapInterval)
      self.idleQuietEnabled = true
    } else {
      @Shared(.settingsFile) var settingsFile
      let capMilliseconds = TerminalEnergyConfiguration.idleQuietFrameCapMilliseconds(
        lowEnergyModeSetting: settingsFile.global.lowEnergyModeEnabled
      )
      self.idleQuietFrameCapMilliseconds = capMilliseconds
      self.idleQuietFrameCapInterval = .milliseconds(capMilliseconds ?? 1)
      self.idleQuietEnabled = capMilliseconds != nil
    }
    TerminalEnergyDiagnostics.shared.recordConfiguredUnfocusedFrameCap(
      milliseconds: unfocusedFrameCapMilliseconds
    )
    if let focusedFrameCapMilliseconds {
      TerminalEnergyDiagnostics.shared.recordConfiguredFocusedFrameCap(
        milliseconds: focusedFrameCapMilliseconds,
        state: focusedFrameCapState
      )
    }
    if let idleQuietFrameCapMilliseconds {
      TerminalEnergyDiagnostics.shared.recordConfiguredIdleQuietGovernor(
        thresholdMilliseconds: idleQuietThresholdMilliseconds,
        capMilliseconds: idleQuietFrameCapMilliseconds
      )
    }
    TerminalEnergyDiagnostics.shared.recordRenderGovernorState(
      focused: focused,
      suspendState: presentationSuspendState,
      capMilliseconds: unfocusedFrameCapMilliseconds,
      idleState: idleQuietState,
      quietCapMilliseconds: idleQuietFrameCapMilliseconds,
      focusedCapMilliseconds: focusedFrameCapMilliseconds,
      focusedCapState: focusedFrameCapState
    )
    self.progressIdleInterval = progressIdleInterval
    self.progressStaleTimeout = progressStaleTimeout
    restartIdleQuietTimerIfNeeded()
  }

  private static func resolvedProgressThrottleMilliseconds() -> Int {
    @Shared(.settingsFile) var settingsFile
    return TerminalEnergyConfiguration.progressThrottleMilliseconds(
      lowEnergyModeSetting: settingsFile.global.lowEnergyModeEnabled
    )
  }

  deinit {
    progressFlushTask?.cancel()
    progressStaleTask?.cancel()
    renderProxyFlushTask?.cancel()
    idleQuietTask?.cancel()
  }

  private struct ProgressUpdate: Equatable {
    let state: ghostty_action_progress_report_state_e
    let value: Int?
  }

  func setFocused(_ focused: Bool) {
    guard self.focused != focused else { return }
    self.focused = focused
    if focused {
      markInteractive(reason: "focus_regain", flushPending: false)
    } else {
      stopIdleQuietTimer(nextState: .inactive)
    }
    recordGovernorState()
    if focused && !presentationSuspendState.isSuspended {
      flushPendingRenderProxy(reason: "focus_regain")
    }
  }

  func setPresentationVisible(_ visible: Bool) {
    let nextState: TerminalPresentationSuspendState = visible ? .visible : .hidden
    guard presentationSuspendState != nextState else { return }
    presentationSuspendState = nextState
    if nextState.isSuspended {
      progressFlushTask?.cancel()
      progressFlushTask = nil
      renderProxyFlushTask?.cancel()
      renderProxyFlushTask = nil
      stopIdleQuietTimer(nextState: .inactive)
    } else {
      restartIdleQuietTimerIfNeeded()
      flushPendingRenderProxy(reason: "presentation_visible")
    }
    recordGovernorState()
  }

  func flushPendingRenderProxy(reason: String) {
    if pendingProgress != nil {
      progressFlushTask?.cancel()
      progressFlushTask = nil
      applyPendingProgress(reason: reason)
    }
    if pendingRenderProxy {
      renderProxyFlushTask?.cancel()
      renderProxyFlushTask = nil
      applyPendingRenderProxy(reason: reason)
    }
  }

  func noteUserInteraction(reason: String) {
    markInteractive(reason: reason, flushPending: true)
  }

  func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
    TerminalEnergyDiagnostics.shared.recordAction()
    if let handled = handleAppAction(action) { return handled }
    if let handled = handleSplitAction(action) { return handled }
    if handleTitleAndPath(action) { return false }
    if handleContextSignal(action) { return false }
    if handleCommandStatus(action) { return false }
    if handleMouseAndLink(action) {
      return action.tag == GHOSTTY_ACTION_OPEN_URL
    }
    if handleRender(action) { return true }
    if handleSearchAndScroll(action) { return false }
    if handleSizeAndKey(action) { return false }
    if handleConfigAndShell(action) { return false }
    return false
  }

  func sendText(_ text: String) {
    guard let surface else { return }
    noteUserInteraction(reason: "terminal_input")
    TerminalEnergyDiagnostics.shared.recordTerminalInput(bytes: text.lengthOfBytes(using: .utf8))
    text.withCString { ptr in
      ghostty_surface_text(surface, ptr, UInt(text.lengthOfBytes(using: .utf8)))
    }
  }

  func sendCommand(_ command: String) {
    let finalCommand = command.hasSuffix("\n") ? command : "\(command)\n"
    sendText(finalCommand)
  }

  func closeSurface(processAlive: Bool) {
    onCloseRequest?(processAlive)
  }

  private func handleAppAction(_ action: ghostty_action_s) -> Bool? {
    switch action.tag {
    case GHOSTTY_ACTION_NEW_TAB:
      return onNewTab?() ?? false
    case GHOSTTY_ACTION_CLOSE_TAB:
      return onCloseTab?(action.action.close_tab_mode) ?? false
    case GHOSTTY_ACTION_GOTO_TAB:
      return onGotoTab?(action.action.goto_tab) ?? false
    case GHOSTTY_ACTION_MOVE_TAB:
      return onMoveTab?(action.action.move_tab) ?? false
    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
      return onCommandPaletteToggle?() ?? false
    case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
      return surfaceView?.toggleBackgroundOpacity() ?? false
    case GHOSTTY_ACTION_GOTO_WINDOW,
      GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
      GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      return false
    case GHOSTTY_ACTION_UNDO:
      NSApp.sendAction(#selector(UndoManager.undo), to: nil, from: nil)
      return true
    case GHOSTTY_ACTION_REDO:
      NSApp.sendAction(#selector(UndoManager.redo), to: nil, from: nil)
      return true
    default:
      return nil
    }
  }

  private func handleSplitAction(_ action: ghostty_action_s) -> Bool? {
    switch action.tag {
    case GHOSTTY_ACTION_NEW_SPLIT:
      let direction = splitDirection(from: action.action.new_split)
      guard let direction else { return false }
      return onSplitAction?(.newSplit(direction: direction)) ?? false

    case GHOSTTY_ACTION_GOTO_SPLIT:
      let direction = focusDirection(from: action.action.goto_split)
      guard let direction else { return false }
      return onSplitAction?(.gotoSplit(direction: direction)) ?? false

    case GHOSTTY_ACTION_RESIZE_SPLIT:
      let resize = action.action.resize_split
      let direction = resizeDirection(from: resize.direction)
      guard let direction else { return false }
      return onSplitAction?(.resizeSplit(direction: direction, amount: resize.amount)) ?? false

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
      return onSplitAction?(.equalizeSplits) ?? false

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
      return onSplitAction?(.toggleSplitZoom) ?? false

    default:
      return nil
    }
  }

  private func splitDirection(from value: ghostty_action_split_direction_e) -> GhosttySplitAction
    .NewDirection?
  {
    switch value {
    case GHOSTTY_SPLIT_DIRECTION_LEFT:
      return .left
    case GHOSTTY_SPLIT_DIRECTION_RIGHT:
      return .right
    case GHOSTTY_SPLIT_DIRECTION_UP:
      return .top
    case GHOSTTY_SPLIT_DIRECTION_DOWN:
      return .down
    default:
      return nil
    }
  }

  private func focusDirection(from value: ghostty_action_goto_split_e) -> GhosttySplitAction
    .FocusDirection?
  {
    switch value {
    case GHOSTTY_GOTO_SPLIT_PREVIOUS:
      return .previous
    case GHOSTTY_GOTO_SPLIT_NEXT:
      return .next
    case GHOSTTY_GOTO_SPLIT_LEFT:
      return .left
    case GHOSTTY_GOTO_SPLIT_RIGHT:
      return .right
    case GHOSTTY_GOTO_SPLIT_UP:
      return .top
    case GHOSTTY_GOTO_SPLIT_DOWN:
      return .down
    default:
      return nil
    }
  }

  private func resizeDirection(from value: ghostty_action_resize_split_direction_e)
    -> GhosttySplitAction.ResizeDirection?
  {
    switch value {
    case GHOSTTY_RESIZE_SPLIT_LEFT:
      return .left
    case GHOSTTY_RESIZE_SPLIT_RIGHT:
      return .right
    case GHOSTTY_RESIZE_SPLIT_UP:
      return .top
    case GHOSTTY_RESIZE_SPLIT_DOWN:
      return .down
    default:
      return nil
    }
  }

  private func handleTitleAndPath(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
      // TUIs re-emit the same title constantly; skip the no-op write + a11y post.
      if let title = string(from: action.action.set_title.title), title != state.title {
        state.title = title
        onTitleChange?(title)
        if let surfaceView {
          NSAccessibility.post(element: surfaceView, notification: .titleChanged)
        }
      }
      return true

    case GHOSTTY_ACTION_PROMPT_TITLE:
      state.promptTitle = action.action.prompt_title
      flushPendingRenderProxy(reason: "prompt_title")
      onPromptTitle?()
      return true

    case GHOSTTY_ACTION_PWD:
      state.pwd = string(from: action.action.pwd.pwd)
      if let surfaceView {
        NSAccessibility.post(element: surfaceView, notification: .valueChanged)
        // VoiceOver does not reliably re-read the label on `.valueChanged` alone.
        // If the surface view's label falls back to PWD, post `.titleChanged` to trigger re-announcement.
        let title = state.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
          NSAccessibility.post(element: surfaceView, notification: .titleChanged)
        }
      }
      return true

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      let note = action.action.desktop_notification
      let title = string(from: note.title) ?? ""
      let body = string(from: note.body) ?? ""
      guard !(title.isEmpty && body.isEmpty) else { return true }
      onDesktopNotification?(title, body)
      return true

    default:
      return false
    }
  }

  private func handleContextSignal(_ action: ghostty_action_s) -> Bool {
    guard action.tag == GHOSTTY_ACTION_CONTEXT_SIGNAL else { return false }
    let signal = action.action.context_signal
    guard let id = string(from: signal.id), let metadata = string(from: signal.metadata) else {
      terminalStateLogger.warning("OSC 3008 context signal arrived with null id or metadata")
      return true
    }
    onContextSignal?(signal.action, id, metadata)
    return true
  }

  private func handleCommandStatus(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_PROGRESS_REPORT:
      let report = action.action.progress_report
      ingestProgressReport(
        state: report.state,
        value: report.progress == -1 ? nil : Int(report.progress)
      )
      return true

    case GHOSTTY_ACTION_COMMAND_FINISHED:
      let info = action.action.command_finished
      let exitCode = info.exit_code == -1 ? nil : Int(info.exit_code)
      state.commandExitCode = exitCode
      state.commandDuration = info.duration
      flushPendingRenderProxy(reason: "command_finished")
      onCommandFinished?(exitCode)
      return true

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      let info = action.action.child_exited
      state.childExitCode = info.exit_code
      state.childExitTimeMs = info.timetime_ms
      flushPendingRenderProxy(reason: "child_exited")
      onChildExited?(info.exit_code)
      return true

    case GHOSTTY_ACTION_READONLY:
      state.readOnly = action.action.readonly
      return true

    case GHOSTTY_ACTION_RING_BELL:
      state.bellCount += 1
      flushPendingRenderProxy(reason: "bell")
      return true

    default:
      return false
    }
  }

  /// Coalescing entry point for OSC-9 progress. REMOVE clears immediately; a
  /// value identical to what's already shown only refreshes the stale window.
  func ingestProgressReport(state: ghostty_action_progress_report_state_e, value: Int?) {
    TerminalEnergyDiagnostics.shared.recordProgressReport()
    guard state != GHOSTTY_PROGRESS_STATE_REMOVE else {
      flushProgressRemoval()
      return
    }
    // The counter is the stale watch's liveness signal; bump it on every report.
    progressReportCount &+= 1
    startProgressStaleWatchIfNeeded()
    let update = ProgressUpdate(state: state, value: value)
    guard update != appliedProgress else {
      TerminalEnergyDiagnostics.shared.recordCoalescedFrameProxy(reason: "osc9_progress_duplicate")
      return
    }
    if pendingProgress != nil {
      TerminalEnergyDiagnostics.shared.recordCoalescedFrameProxy(reason: "osc9_progress_pending")
    }
    pendingProgress = update
    scheduleProgressFlush()
  }

  /// Leading-edge then trailing throttle: paint a new value immediately when no
  /// flush is in flight, then batch any further changes into one flush per
  /// throttle interval. Idles to nothing once the value stops moving.
  private func scheduleProgressFlush() {
    guard !presentationSuspendState.isSuspended else { return }
    guard progressFlushTask == nil else { return }
    applyPendingProgress(reason: "osc9_progress")
    progressFlushTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await self.clock.sleep(for: self.currentRenderCadenceInterval)
      // Check cancellation before clearing the handle: a cancelled task (REMOVE
      // raced a reschedule) must not clobber the live task's handle.
      guard !Task.isCancelled else { return }
      self.progressFlushTask = nil
      guard self.pendingProgress != nil else { return }
      self.scheduleProgressFlush()
    }
  }

  /// Slow watch that clears a bar whose reports stopped without a REMOVE (e.g.
  /// the process died). Wakes at the idle cadence, not the throttle cadence, so
  /// a held bar doesn't pin a high-frequency wakeup on the main thread.
  private func startProgressStaleWatchIfNeeded() {
    guard progressStaleTask == nil else { return }
    let startCount = progressReportCount
    progressStaleTask = Task { @MainActor [weak self] in
      guard let self else { return }
      var lastSeenCount = startCount
      var idleElapsed: Duration = .zero
      while !Task.isCancelled {
        try? await self.clock.sleep(for: self.progressIdleInterval)
        guard !Task.isCancelled else { return }
        if self.progressReportCount != lastSeenCount {
          lastSeenCount = self.progressReportCount
          idleElapsed = .zero
          continue
        }
        idleElapsed += self.progressIdleInterval
        if idleElapsed >= self.progressStaleTimeout {
          self.flushProgressRemoval()
          return
        }
      }
    }
  }

  private var currentRenderCadenceInterval: Duration {
    if !focused { return unfocusedFrameCapInterval }
    if idleQuietState == .idleQuiet, idleQuietFrameCapMilliseconds != nil {
      return idleQuietFrameCapInterval
    }
    if let focusedFrameCapInterval { return focusedFrameCapInterval }
    return progressThrottleInterval
  }

  private func applyPendingProgress(reason: String) {
    guard let pending = pendingProgress else { return }
    pendingProgress = nil
    guard pending != appliedProgress else { return }
    appliedProgress = pending
    state.progressState = pending.state
    state.progressValue = pending.value
    TerminalEnergyDiagnostics.shared.recordProgressApply(state: Self.progressStateName(pending.state))
    onProgressReport?(pending.state)
  }

  private func handleRender(_ action: ghostty_action_s) -> Bool {
    guard action.tag == GHOSTTY_ACTION_RENDER else { return false }
    ingestRenderRequest(reason: "render")
    return true
  }

  func ingestRenderRequest(reason: String) {
    TerminalEnergyDiagnostics.shared.recordPresentationRequest(reason: reason)
    if pendingRenderProxy {
      TerminalEnergyDiagnostics.shared.recordCoalescedFrameProxy(reason: reason)
    }
    pendingRenderProxy = true
    scheduleRenderProxyFlush()
  }

  private func scheduleRenderProxyFlush() {
    guard !presentationSuspendState.isSuspended else { return }
    guard renderProxyFlushTask == nil else { return }
    applyPendingRenderProxy(reason: "render")
    renderProxyFlushTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await self.clock.sleep(for: self.currentRenderCadenceInterval)
      guard !Task.isCancelled else { return }
      self.renderProxyFlushTask = nil
      guard self.pendingRenderProxy else { return }
      self.scheduleRenderProxyFlush()
    }
  }

  private func applyPendingRenderProxy(reason: String) {
    guard pendingRenderProxy else { return }
    pendingRenderProxy = false
    TerminalEnergyDiagnostics.shared.recordCommittedFrameProxy(reason: reason)
    onRenderProxyCommit?()
  }

  private func markInteractive(reason: String, flushPending: Bool) {
    guard idleQuietEnabled else {
      if flushPending {
        flushPendingRenderProxy(reason: reason)
      }
      return
    }
    stopIdleQuietTimer(nextState: .interactive)
    recordGovernorState()
    if flushPending {
      flushPendingRenderProxy(reason: reason)
    }
    restartIdleQuietTimerIfNeeded()
  }

  private func restartIdleQuietTimerIfNeeded() {
    guard idleQuietEnabled, focused, !presentationSuspendState.isSuspended else { return }
    idleQuietTask?.cancel()
    if idleQuietState != .interactive {
      idleQuietState = .interactive
      recordGovernorState()
    }
    idleQuietTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await self.clock.sleep(for: self.idleQuietThreshold)
      guard !Task.isCancelled else { return }
      self.idleQuietTask = nil
      self.idleQuietState = .idleQuiet
      self.recordGovernorState()
    }
  }

  private func stopIdleQuietTimer(nextState: TerminalIdleQuietState) {
    idleQuietTask?.cancel()
    idleQuietTask = nil
    idleQuietState = nextState
  }

  private func recordGovernorState() {
    TerminalEnergyDiagnostics.shared.recordRenderGovernorState(
      focused: focused,
      suspendState: presentationSuspendState,
      capMilliseconds: unfocusedFrameCapMilliseconds,
      idleState: idleQuietState,
      quietCapMilliseconds: idleQuietFrameCapMilliseconds,
      focusedCapMilliseconds: focusedFrameCapMilliseconds,
      focusedCapState: focusedFrameCapState
    )
  }

  private func flushProgressRemoval() {
    // REMOVE wins over any unapplied trailing value: applying it first would
    // emit a spurious determinate paint that coalesces away before render,
    // since the bar is clearing anyway.
    progressFlushTask?.cancel()
    progressFlushTask = nil
    progressStaleTask?.cancel()
    progressStaleTask = nil
    pendingProgress = nil
    appliedProgress = nil
    state.progressState = nil
    state.progressValue = nil
    TerminalEnergyDiagnostics.shared.recordProgressApply(state: "remove")
    onProgressReport?(GHOSTTY_PROGRESS_STATE_REMOVE)
  }

  private func handleMouseAndLink(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_MOUSE_SHAPE:
      state.mouseShape = action.action.mouse_shape
      surfaceView?.setMouseShape(action.action.mouse_shape)
      return true

    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      state.mouseVisibility = action.action.mouse_visibility
      surfaceView?.setMouseVisibility(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
      return true

    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
      let link = action.action.mouse_over_link
      state.mouseOverLink = string(from: link.url, length: link.len)
      return true

    case GHOSTTY_ACTION_RENDERER_HEALTH:
      state.rendererHealth = action.action.renderer_health
      return true

    case GHOSTTY_ACTION_OPEN_URL:
      let openUrl = action.action.open_url
      state.openUrlKind = openUrl.kind
      let rawUrl = string(from: openUrl.url, length: openUrl.len)
      state.openUrl = rawUrl
      if let request = ghosttyOpenURLRequest(urlString: rawUrl, kind: openUrl.kind) {
        SupaLogger("GhosttySurfaceBridge").debug("OPEN_URL raw=\(rawUrl ?? "nil") resolved=\(request.url)")
        NSWorkspace.shared.open(request.url)
      }
      return true

    case GHOSTTY_ACTION_COLOR_CHANGE:
      let change = action.action.color_change
      // Only OSC 11 (background) drives the window tint; storing other kinds
      // here would clobber the active background and reset the tint to theme.
      guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return true }
      state.colorChangeKind = change.kind
      state.colorChangeR = change.r
      state.colorChangeG = change.g
      state.colorChangeB = change.b
      onColorChanged?()
      return true

    default:
      return false
    }
  }

  private func handleSearchAndScroll(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_SCROLLBAR:
      let scroll = action.action.scrollbar
      surfaceView?.updateScrollbar(
        total: scroll.total,
        offset: scroll.offset,
        length: scroll.len
      )
      return true

    case GHOSTTY_ACTION_START_SEARCH:
      let needle = string(from: action.action.start_search.needle) ?? ""
      if !needle.isEmpty {
        state.searchNeedle = needle
      } else if state.searchNeedle == nil {
        state.searchNeedle = ""
      }
      state.searchTotal = nil
      state.searchSelected = nil
      state.searchFocusCount += 1
      return true

    case GHOSTTY_ACTION_END_SEARCH:
      state.searchNeedle = nil
      state.searchTotal = nil
      state.searchSelected = nil
      return true

    case GHOSTTY_ACTION_SEARCH_TOTAL:
      let total = action.action.search_total.total
      state.searchTotal = total < 0 ? nil : Int(total)
      return true

    case GHOSTTY_ACTION_SEARCH_SELECTED:
      let selected = action.action.search_selected.selected
      state.searchSelected = selected < 0 ? nil : Int(selected)
      return true

    default:
      return false
    }
  }

  private func handleSizeAndKey(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_SIZE_LIMIT:
      let sizeLimit = action.action.size_limit
      state.sizeLimitMinWidth = sizeLimit.min_width
      state.sizeLimitMinHeight = sizeLimit.min_height
      state.sizeLimitMaxWidth = sizeLimit.max_width
      state.sizeLimitMaxHeight = sizeLimit.max_height
      return true

    case GHOSTTY_ACTION_INITIAL_SIZE:
      let initial = action.action.initial_size
      state.initialSizeWidth = initial.width
      state.initialSizeHeight = initial.height
      return true

    case GHOSTTY_ACTION_CELL_SIZE:
      let cell = action.action.cell_size
      surfaceView?.updateCellSize(width: cell.width, height: cell.height)
      return true

    case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
      state.resetWindowSizeCount += 1
      return true

    case GHOSTTY_ACTION_KEY_SEQUENCE:
      let seq = action.action.key_sequence
      state.keySequenceActive = seq.active
      state.keySequenceTrigger = seq.trigger
      return true

    case GHOSTTY_ACTION_KEY_TABLE:
      let table = action.action.key_table
      state.keyTableTag = table.tag
      switch table.tag {
      case GHOSTTY_KEY_TABLE_ACTIVATE:
        state.keyTableName = string(
          from: table.value.activate.name, length: table.value.activate.len)
        state.keyTableDepth += 1
      case GHOSTTY_KEY_TABLE_DEACTIVATE:
        state.keyTableName = nil
        if state.keyTableDepth > 0 {
          state.keyTableDepth -= 1
        }
      case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
        state.keyTableName = nil
        state.keyTableDepth = 0
      default:
        state.keyTableName = nil
      }
      return true

    default:
      return false
    }
  }

  private func handleConfigAndShell(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_SECURE_INPUT:
      state.secureInput = action.action.secure_input
      switch action.action.secure_input {
      case GHOSTTY_SECURE_INPUT_ON:
        surfaceView?.passwordInput = true
      case GHOSTTY_SECURE_INPUT_OFF:
        surfaceView?.passwordInput = false
      case GHOSTTY_SECURE_INPUT_TOGGLE:
        surfaceView?.passwordInput.toggle()
      default:
        break
      }
      return true

    case GHOSTTY_ACTION_FLOAT_WINDOW:
      state.floatWindow = action.action.float_window
      return true

    case GHOSTTY_ACTION_RELOAD_CONFIG:
      state.reloadConfigSoft = action.action.reload_config.soft
      return true

    case GHOSTTY_ACTION_CONFIG_CHANGE:
      state.configChangeCount += 1
      return true

    case GHOSTTY_ACTION_OPEN_CONFIG:
      state.openConfigCount += 1
      return true

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
      state.presentTerminalCount += 1
      return true
    case GHOSTTY_ACTION_QUIT_TIMER:
      state.quitTimer = action.action.quit_timer
      return true

    default:
      return false
    }
  }

  private static func progressStateName(_ state: ghostty_action_progress_report_state_e) -> String {
    switch state {
    case GHOSTTY_PROGRESS_STATE_REMOVE:
      return "remove"
    case GHOSTTY_PROGRESS_STATE_SET:
      return "set"
    case GHOSTTY_PROGRESS_STATE_INDETERMINATE:
      return "indeterminate"
    default:
      return "unknown"
    }
  }

  private static func durationMilliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    let seconds = components.seconds * 1_000
    let attoseconds = components.attoseconds / 1_000_000_000_000_000
    return max(1, Int(seconds + attoseconds))
  }

  private func string(from pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
  }

  private func string(from pointer: UnsafePointer<CChar>?, length: Int) -> String? {
    guard let pointer, length > 0 else { return nil }
    let data = Data(bytes: pointer, count: length)
    return String(data: data, encoding: .utf8)
  }

  private func string(from pointer: UnsafePointer<CChar>?, length: UInt) -> String? {
    string(from: pointer, length: Int(length))
  }

  private func string(from pointer: UnsafePointer<CChar>?, length: UInt64) -> String? {
    string(from: pointer, length: Int(length))
  }
}
