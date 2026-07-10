import Foundation
import SupacodeSettingsShared

@MainActor
final class TerminalEnergyDiagnostics {
  static let shared = TerminalEnergyDiagnostics()

  private struct Snapshot {
    var actions = 0
    var presentationRequests = 0
    var committedFrameProxies = 0
    var coalescedFrameProxies = 0
    var progressReports = 0
    var progressApplies = 0
    var progressRemovals = 0
    var terminalInputBytes = 0
    var scrollCommits = 0
    var sizeUpdates = 0
    var layoutPasses = 0
  }

  private let logger = SupaLogger("Energy")
  private let enabled: Bool
  private let statsFileURL: URL?
  private var snapshot = Snapshot()
  private var summaryTask: Task<Void, Never>?
  private var lastSummaryTime = ContinuousClock.now
  private var configuredProgressThrottleMilliseconds: Int?
  private var configuredUnfocusedFrameCapMilliseconds: Int?
  private var workloadName: String
  private var workloadState: String
  private var focusState = "unknown"
  private var occlusionState = "unknown"
  private var governorState = "none"
  private var capState = "none"
  private var capFPS = "0.00"

  private init(
    enabled: Bool = TerminalEnergyConfiguration.renderStatsEnabled(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.enabled = enabled
    self.statsFileURL = Self.statsFileURL(environment: environment)
    self.workloadName = Self.metadataValue("SUPACODE_ENERGY_WORKLOAD", environment: environment)
    self.workloadState = Self.metadataValue("SUPACODE_ENERGY_STATE", environment: environment)
    if enabled {
      startSummaryLoop()
    }
  }

  deinit {
    summaryTask?.cancel()
  }

  func recordAction() {
    guard enabled else { return }
    snapshot.actions += 1
  }

  func recordPresentationRequest(reason: String) {
    guard enabled else { return }
    snapshot.presentationRequests += 1
  }

  func recordCommittedFrameProxy(reason: String) {
    guard enabled else { return }
    snapshot.committedFrameProxies += 1
  }

  func recordCoalescedFrameProxy(reason: String) {
    guard enabled else { return }
    snapshot.coalescedFrameProxies += 1
  }

  func recordFocusState(_ focused: Bool) {
    guard enabled else { return }
    focusState = focused ? "focused" : "unfocused"
  }

  func recordRenderGovernorState(focused: Bool, capMilliseconds: Int) {
    guard enabled else { return }
    guard !focused else {
      governorState = "focused_passthrough"
      capState = "none"
      capFPS = "0.00"
      return
    }
    governorState = "background_unfocused_cap"
    capState = "active"
    capFPS = Self.format(1_000 / Double(max(1, capMilliseconds)))
  }

  func recordOcclusionState(visible: Bool) {
    guard enabled else { return }
    occlusionState = visible ? "visible" : "occluded"
  }

  func recordProgressReport() {
    guard enabled else { return }
    snapshot.progressReports += 1
    recordPresentationRequest(reason: "osc9_progress")
  }

  func recordProgressApply(state: String) {
    guard enabled else { return }
    snapshot.progressApplies += 1
    recordCommittedFrameProxy(reason: "osc9_progress")
    if state == "remove" {
      snapshot.progressRemovals += 1
    }
  }

  func recordTerminalInput(bytes: Int) {
    guard enabled else { return }
    snapshot.terminalInputBytes += bytes
  }

  func recordScrollCommit() {
    guard enabled else { return }
    snapshot.scrollCommits += 1
    recordPresentationRequest(reason: "scroll")
    recordCommittedFrameProxy(reason: "scroll")
  }

  func recordSizeUpdate() {
    guard enabled else { return }
    snapshot.sizeUpdates += 1
    recordPresentationRequest(reason: "size")
    recordCommittedFrameProxy(reason: "size")
  }

  func recordLayoutPass() {
    guard enabled else { return }
    snapshot.layoutPasses += 1
    recordPresentationRequest(reason: "layout")
    recordCommittedFrameProxy(reason: "layout")
  }

  func recordConfiguredProgressThrottle(milliseconds: Int) {
    guard enabled else { return }
    guard configuredProgressThrottleMilliseconds != milliseconds else { return }
    configuredProgressThrottleMilliseconds = milliseconds
    log("render_stats: enabled progress_throttle_ms=\(milliseconds)")
  }

  func recordConfiguredUnfocusedFrameCap(milliseconds: Int) {
    guard enabled else { return }
    guard configuredUnfocusedFrameCapMilliseconds != milliseconds else { return }
    configuredUnfocusedFrameCapMilliseconds = milliseconds
    log("render_stats: enabled unfocused_frame_cap_ms=\(milliseconds)")
  }

  private func startSummaryLoop() {
    guard summaryTask == nil else { return }
    summaryTask = Task { @MainActor [weak self] in
      let clock = ContinuousClock()
      while !Task.isCancelled {
        try? await clock.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        self?.logSummary()
      }
    }
  }

  private func logSummary() {
    let now = ContinuousClock.now
    let elapsed = lastSummaryTime.duration(to: now)
    let seconds = max(0.001, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    let current = snapshot
    snapshot = Snapshot()
    lastSummaryTime = now
    log(Self.summaryLine(
      seconds: seconds,
      actions: current.actions,
      presentationRequests: current.presentationRequests,
      committedFrameProxies: current.committedFrameProxies,
      coalescedFrameProxies: current.coalescedFrameProxies,
      progressReports: current.progressReports,
      progressApplies: current.progressApplies,
      progressRemovals: current.progressRemovals,
      terminalInputBytes: current.terminalInputBytes,
      scrollCommits: current.scrollCommits,
      sizeUpdates: current.sizeUpdates,
      layoutPasses: current.layoutPasses,
      workloadName: workloadName,
      workloadState: workloadState,
      focusState: focusState,
      occlusionState: occlusionState,
      governorState: governorState,
      capState: capState,
      capFPS: capFPS
    ))
  }

  private func log(_ message: String) {
    logger.info(message)
    appendStatsFile(message)
  }

  private func appendStatsFile(_ message: String) {
    guard let statsFileURL else { return }
    let data = Data("[Energy] \(message)\n".utf8)
    do {
      if FileManager.default.fileExists(atPath: statsFileURL.path) {
        let handle = try FileHandle(forWritingTo: statsFileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
      } else {
        try data.write(to: statsFileURL, options: .atomic)
      }
    } catch {
      logger.warning("render_stats_file_write_failed: \(error)")
    }
  }

  private static func rate(_ count: Int, seconds: Double) -> String {
    format(Double(count) / seconds)
  }

  static func summaryLine(
    seconds: Double,
    actions: Int,
    presentationRequests: Int,
    committedFrameProxies: Int,
    coalescedFrameProxies: Int,
    progressReports: Int,
    progressApplies: Int,
    progressRemovals: Int,
    terminalInputBytes: Int,
    scrollCommits: Int,
    sizeUpdates: Int,
    layoutPasses: Int,
    workloadName: String,
    workloadState: String,
    focusState: String,
    occlusionState: String,
    governorState: String = "none",
    capState: String = "none",
    capFPS: String = "0.00"
  ) -> String {
    let safeSeconds = max(0.001, seconds)
    return "render_stats: interval_s=\(format(safeSeconds)) workload=\(workloadName) state=\(workloadState) render_counter_source=appkit_proxy governor_state=\(governorState) cap_state=\(capState) cap_fps=\(capFPS) suspend_state=none focus_state=\(focusState) occlusion_state=\(occlusionState) idle_state=unknown presentation_requests_per_s=\(rate(presentationRequests, seconds: safeSeconds)) committed_frame_proxies_per_s=\(rate(committedFrameProxies, seconds: safeSeconds)) coalesced_frame_proxies_per_s=\(rate(coalescedFrameProxies, seconds: safeSeconds)) actions_per_s=\(rate(actions, seconds: safeSeconds)) progress_reports_per_s=\(rate(progressReports, seconds: safeSeconds)) progress_applies_per_s=\(rate(progressApplies, seconds: safeSeconds)) progress_removals=\(progressRemovals) terminal_input_bytes_per_s=\(rate(terminalInputBytes, seconds: safeSeconds)) scroll_commits_per_s=\(rate(scrollCommits, seconds: safeSeconds)) size_updates_per_s=\(rate(sizeUpdates, seconds: safeSeconds)) layout_passes_per_s=\(rate(layoutPasses, seconds: safeSeconds))"
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.2f", value)
  }

  static func progressThrottleMillisecondsForSummary(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    lowEnergyModeSetting: Bool
  ) -> Int {
    TerminalEnergyConfiguration.progressThrottleMilliseconds(
      environment: environment,
      lowEnergyModeSetting: lowEnergyModeSetting
    )
  }

  static func statsFileURL(environment: [String: String]) -> URL? {
    guard let path = environment["SUPACODE_RENDER_STATS_FILE"], !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path)
  }

  static func metadataValue(_ name: String, environment: [String: String]) -> String {
    guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return "unspecified" }
    return value
  }
}
