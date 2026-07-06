import Clocks
import Foundation
import GhosttyKit
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

// Serialized: the coalescing tests drive a TestClock with two concurrent
// sleepers (flush + stale watch); parallel execution can race `advance` before
// a task suspends and flake.
@MainActor
@Suite(.serialized)
struct GhosttySurfaceBridgeTests {
  @Test
  func openUrlRequestPreservesHTTPSURL() {
    let request = ghosttyOpenURLRequest(
      urlString: "https://supacode.dev/changelog",
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    )

    #expect(request?.kind == .unknown)
    #expect(request?.url.absoluteString == "https://supacode.dev/changelog")
    #expect(request?.url.isFileURL == false)
  }

  @Test
  func openUrlRequestTreatsTildePathAsFileURL() {
    let request = ghosttyOpenURLRequest(
      urlString: "~/code/github.com/supabitapp/supacode",
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    )

    #expect(request?.url.isFileURL == true)
    #expect(
      request?.url.path
        == FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "code/github.com/supabitapp/supacode").path
    )
  }

  @Test
  func openUrlRequestExpandsNamedTildePathAsFileURL() {
    let username = NSUserName()
    let input = "~\(username)/code/github.com/supabitapp/supacode"
    let request = ghosttyOpenURLRequest(
      urlString: input,
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    )

    #expect(request?.url.isFileURL == true)
    #expect(request?.url.path == NSString(string: input).expandingTildeInPath)
  }

  @Test
  func openUrlRequestTreatsPlainPathWithSpacesAsFileURL() {
    let request = ghosttyOpenURLRequest(
      urlString: "/tmp/supa code/output.txt",
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
    )

    #expect(request?.kind == .text)
    #expect(request?.url.isFileURL == true)
    #expect(request?.url.path == "/tmp/supa code/output.txt")
  }

  @Test
  func openUrlRequestTreatsUnknownStringAsFilePath() {
    let request = ghosttyOpenURLRequest(
      urlString: "relative/path",
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    )

    #expect(request?.url.isFileURL == true)
  }

  @Test
  func openUrlReturnsHandledResult() {
    let bridge = GhosttySurfaceBridge()
    let target = ghostty_target_s(tag: GHOSTTY_TARGET_SURFACE, target: .init())

    withOpenURLAction(url: "/tmp/test") { action in
      #expect(bridge.handleAction(target: target, action: action))
      #expect(bridge.state.openUrl == "/tmp/test")
      #expect(bridge.state.openUrlKind == action.action.open_url.kind)
    }
  }

  @Test func desktopNotificationEmitsCallback() {
    let bridge = GhosttySurfaceBridge()
    var received: (title: String, body: String)?
    bridge.onDesktopNotification = { title, body in
      received = (title, body)
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_DESKTOP_NOTIFICATION
    let target = ghostty_target_s()

    "Title".withCString { titlePtr in
      "Body".withCString { bodyPtr in
        action.action.desktop_notification = ghostty_action_desktop_notification_s(
          title: titlePtr,
          body: bodyPtr
        )
        _ = bridge.handleAction(target: target, action: action)
      }
    }

    #expect(received?.title == "Title")
    #expect(received?.body == "Body")
  }

  @Test func contextSignalEmitsCallback() {
    let bridge = GhosttySurfaceBridge()
    var receivedAction: UInt8?
    var receivedID: String?
    var receivedMetadata: String?
    bridge.onContextSignal = { action, id, metadata in
      receivedAction = action
      receivedID = id
      receivedMetadata = metadata
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_CONTEXT_SIGNAL
    let target = ghostty_target_s()

    "claude".withCString { idPtr in
      "event=busy".withCString { metaPtr in
        action.action.context_signal = ghostty_action_context_signal_s(
          action: 0,
          id: idPtr,
          metadata: metaPtr
        )
        _ = bridge.handleAction(target: target, action: action)
      }
    }

    #expect(receivedAction == 0)
    #expect(receivedID == "claude")
    #expect(receivedMetadata == "event=busy")
  }

  @Test func contextSignalDropsNullIDOrMetadata() {
    let bridge = GhosttySurfaceBridge()
    var invoked = false
    bridge.onContextSignal = { _, _, _ in invoked = true }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_CONTEXT_SIGNAL
    let target = ghostty_target_s()

    // Null id with valid metadata.
    "event=busy".withCString { metaPtr in
      action.action.context_signal = ghostty_action_context_signal_s(
        action: 0,
        id: nil,
        metadata: metaPtr
      )
      _ = bridge.handleAction(target: target, action: action)
    }
    #expect(invoked == false)

    // Valid id with null metadata.
    "claude".withCString { idPtr in
      action.action.context_signal = ghostty_action_context_signal_s(
        action: 0,
        id: idPtr,
        metadata: nil
      )
      _ = bridge.handleAction(target: target, action: action)
    }
    #expect(invoked == false)
  }

  @Test func coalescesBurstOfProgressReports() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    var callbackCount = 0
    bridge.onProgressReport = { _ in callbackCount += 1 }

    // Leading edge applies the first report immediately; the rest coalesce.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 10)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 20)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 50)
    #expect(bridge.state.progressValue == 10)
    #expect(callbackCount == 1)

    // One throttle tick flushes only the latest coalesced value.
    await clock.advance(by: .milliseconds(50))
    #expect(bridge.state.progressValue == 50)
    #expect(callbackCount == 2)
  }

  @Test func staleProgressClearsAfterTimeout() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .milliseconds(200)
    )
    var lastState: ghostty_action_progress_report_state_e?
    bridge.onProgressReport = { lastState = $0 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)

    // No further reports: the driver synthesizes a REMOVE once the window lapses.
    await clock.advance(by: .milliseconds(200))
    #expect(bridge.state.progressState == nil)
    #expect(lastState == GHOSTTY_PROGRESS_STATE_REMOVE)
  }

  @Test func continuedReportsKeepProgressAlivePastStaleWindow() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .milliseconds(100)
    )
    var lastState: ghostty_action_progress_report_state_e?
    bridge.onProgressReport = { lastState = $0 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    // A long indeterminate run re-fires identical reports; the stale timer must
    // keep resetting even though the value never changes.
    for _ in 0..<6 {
      bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
      await clock.advance(by: .milliseconds(50))
    }
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
    #expect(lastState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
  }

  @Test func progressDriverRestartsAfterStaleRemoval() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .milliseconds(100)
    )
    bridge.onProgressReport = { _ in }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    // No further reports: the stale window synthesizes a REMOVE and tears down
    // the driver.
    await clock.advance(by: .milliseconds(100))
    #expect(bridge.state.progressState == nil)

    // A report after the stale REMOVE must re-arm the driver, not freeze.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 30)
    #expect(bridge.state.progressValue == 30)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 60)
    await clock.advance(by: .milliseconds(50))
    #expect(bridge.state.progressValue == 60)
  }

  @Test func determinateValuePaintsPromptlyAfterIdlePeriod() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    bridge.onProgressReport = { _ in }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 10)
    #expect(bridge.state.progressValue == 10)

    // Sit idle well past the throttle window, then a fresh value must paint on
    // its leading edge instead of waiting for a slow idle tick.
    await clock.advance(by: .seconds(1))
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 80)
    #expect(bridge.state.progressValue == 80)
  }

  @Test func identicalReportsNeverReapply() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    var callbackCount = 0
    bridge.onProgressReport = { _ in callbackCount += 1 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    #expect(callbackCount == 1)

    // A flood of identical reports keeps the bar alive but never re-applies, so
    // the downstream callback fires exactly once across the whole stream.
    for _ in 0..<10 {
      bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
      await clock.advance(by: .milliseconds(50))
    }
    #expect(callbackCount == 1)
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
  }

  @Test func removeWinsOverUnappliedTrailingValue() {
    let bridge = GhosttySurfaceBridge(
      clock: TestClock(),
      progressThrottleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    var states: [ghostty_action_progress_report_state_e] = []
    bridge.onProgressReport = { states.append($0) }

    // First SET applies on the leading edge; the second sits un-applied in
    // pendingProgress because no throttle tick has fired yet.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 50)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 100)
    // REMOVE before the tick drops the trailing 100 and clears.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_REMOVE, value: nil)

    #expect(bridge.state.progressState == nil)
    #expect(bridge.state.progressValue == nil)
    #expect(states == [GHOSTTY_PROGRESS_STATE_SET, GHOSTTY_PROGRESS_STATE_REMOVE])
  }

  @Test func removeRacingRescheduleKeepsFlushHealthy() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    var applied: [Int?] = []
    bridge.onProgressReport = { state in
      if state != GHOSTTY_PROGRESS_STATE_REMOVE { applied.append(bridge.state.progressValue) }
    }

    // REMOVE cancels the in-flight flush task while a new run starts at once.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 50)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 80)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_REMOVE, value: nil)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 30)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 90)

    // The cancelled task resuming must not clobber the new run's flush handle:
    // each distinct value flushes exactly once (leading 50, leading 30 after
    // the REMOVE, trailing 90), with no redundant re-apply.
    await clock.advance(by: .milliseconds(50))
    #expect(bridge.state.progressValue == 90)
    #expect(applied == [50, 30, 90])
  }

  @Test func removeReportClearsImmediately() {
    let bridge = GhosttySurfaceBridge(clock: TestClock())
    var lastState: ghostty_action_progress_report_state_e?
    bridge.onProgressReport = { lastState = $0 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 42)
    #expect(bridge.state.progressValue == 42)

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_REMOVE, value: nil)
    #expect(bridge.state.progressState == nil)
    #expect(bridge.state.progressValue == nil)
    #expect(lastState == GHOSTTY_PROGRESS_STATE_REMOVE)
  }

  @Test func energyConfigurationUsesDefaultProgressThrottle() {
    #expect(TerminalEnergyConfiguration.progressThrottleMilliseconds(environment: [:]) == 50)
  }

  @Test func energyConfigurationUsesEnergyModeProgressThrottle() {
    #expect(
      TerminalEnergyConfiguration.progressThrottleMilliseconds(
        environment: ["SUPACODE_ENERGY_MODE": "1"]
      ) == 250
    )
  }

  @Test func energyConfigurationExplicitThrottleOverridesEnergyMode() {
    #expect(
      TerminalEnergyConfiguration.progressThrottleMilliseconds(
        environment: [
          "SUPACODE_ENERGY_MODE": "1",
          "SUPACODE_PROGRESS_THROTTLE_MS": "125",
        ]
      ) == 125
    )
  }

  @Test func energyConfigurationRenderStatsHonorsDebugFlags() {
    #expect(
      TerminalEnergyConfiguration.renderStatsEnabled(
        environment: ["SUPACODE_RENDER_STATS": "true"]
      )
    )
    #expect(
      TerminalEnergyConfiguration.renderStatsEnabled(
        environment: ["SUPACODE_ENERGY_DEBUG": "1"]
      )
    )
    #expect(
      TerminalEnergyConfiguration.renderStatsEnabled(
        environment: ["SUPACODE_RENDER_STATS": "0"]
      ) == false
    )
  }

  // MARK: - Energy: quantified render-commit reduction

  /// Spinner/progress-only workload: a determinate bar animating through many
  /// distinct values at ~50fps. This is the Gate 3 scenario from the energy
  /// brief. The coalescer must turn a high-frequency mutation stream into a
  /// low-frequency committed-render stream. Asserts the >=70% render-commit
  /// reduction target directly, measured as applied renders vs raw mutations.
  @Test func energyModeCoalescesSpinnerBurstByAtLeast70Percent() async {
    let clock = TestClock()
    let rawMutations = 100
    let stepMs = 20  // ~50fps mutation cadence
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      // Energy mode cadence (SUPACODE_ENERGY_MODE=1 -> 250ms).
      progressThrottleInterval: .milliseconds(TerminalEnergyConfiguration.energyModeProgressThrottleMs),
      // Keep the stale watch far outside the workload window so it never
      // synthesizes a REMOVE mid-burst and pollutes the apply count.
      progressIdleInterval: .seconds(60),
      progressStaleTimeout: .seconds(600)
    )
    var appliedRenders = 0
    bridge.onProgressReport = { state in
      if state != GHOSTTY_PROGRESS_STATE_REMOVE { appliedRenders += 1 }
    }

    // Animate a determinate bar through `rawMutations` distinct values, each a
    // fresh mutation the naive path would paint immediately.
    for i in 0..<rawMutations {
      let value = i % 101  // distinct, sweeping 0..100
      bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: value)
      await clock.advance(by: .milliseconds(stepMs))
    }

    // Every raw mutation was a distinct value, so the naive (uncoalesced) path
    // would commit `rawMutations` renders. Measure what actually committed.
    let reduction = Double(rawMutations - appliedRenders) / Double(rawMutations)
    #expect(
      reduction >= 0.70,
      "expected >=70% render-commit reduction, got \(Int(reduction * 100))% (\(appliedRenders) applied of \(rawMutations) raw)"
    )
    // The bar must still track live: the final committed value is never stale
    // by more than one throttle window, so output correctness is preserved.
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_SET)
  }

  /// Energy mode must throttle strictly harder than the default cadence for the
  /// same workload: fewer committed renders, proving the flag actually buys
  /// energy headroom rather than being a no-op relabel.
  @Test func energyModeCommitsFewerRendersThanDefault() async {
    func appliedRenders(throttleMs: Int) async -> Int {
      let clock = TestClock()
      let bridge = GhosttySurfaceBridge(
        clock: clock,
        progressThrottleInterval: .milliseconds(throttleMs),
        progressIdleInterval: .seconds(60),
        progressStaleTimeout: .seconds(600)
      )
      var count = 0
      bridge.onProgressReport = { state in
        if state != GHOSTTY_PROGRESS_STATE_REMOVE { count += 1 }
      }
      for i in 0..<100 {
        bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: i % 101)
        await clock.advance(by: .milliseconds(20))
      }
      return count
    }

    let defaultRenders = await appliedRenders(
      throttleMs: TerminalEnergyConfiguration.defaultProgressThrottleMs
    )
    let energyRenders = await appliedRenders(
      throttleMs: TerminalEnergyConfiguration.energyModeProgressThrottleMs
    )

    #expect(
      energyRenders < defaultRenders,
      "energy mode (\(energyRenders)) must commit fewer renders than default (\(defaultRenders))"
    )
  }

  private func withOpenURLAction<T>(
    url: String,
    kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
    _ body: (ghostty_action_s) -> T
  ) -> T {
    var action = ghostty_action_s(tag: GHOSTTY_ACTION_OPEN_URL, action: .init())
    action.action.open_url.kind = kind
    guard let pointer = strdup(url) else {
      Issue.record("strdup failed")
      return body(action)
    }
    defer {
      free(pointer)
    }
    action.action.open_url.url = UnsafePointer(pointer)
    action.action.open_url.len = UInt(strlen(pointer))
    return body(action)
  }
}
