import Foundation
import SupacodeSettingsShared

@MainActor
final class TerminalEnergyDiagnostics {
  static let shared = TerminalEnergyDiagnostics()

  private struct Snapshot {
    var actions = 0
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

  private init(
    enabled: Bool = TerminalEnergyConfiguration.renderStatsEnabled(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.enabled = enabled
    self.statsFileURL = Self.statsFileURL(environment: environment)
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

  func recordProgressReport() {
    guard enabled else { return }
    snapshot.progressReports += 1
  }

  func recordProgressApply(state: String) {
    guard enabled else { return }
    snapshot.progressApplies += 1
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
  }

  func recordSizeUpdate() {
    guard enabled else { return }
    snapshot.sizeUpdates += 1
  }

  func recordLayoutPass() {
    guard enabled else { return }
    snapshot.layoutPasses += 1
  }

  func recordConfiguredProgressThrottle(milliseconds: Int) {
    guard enabled else { return }
    guard configuredProgressThrottleMilliseconds != milliseconds else { return }
    configuredProgressThrottleMilliseconds = milliseconds
    log("render_stats: enabled progress_throttle_ms=\(milliseconds)")
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
    log(
      "render_stats: interval_s=\(Self.format(seconds)) actions_per_s=\(Self.rate(current.actions, seconds: seconds)) progress_reports_per_s=\(Self.rate(current.progressReports, seconds: seconds)) progress_applies_per_s=\(Self.rate(current.progressApplies, seconds: seconds)) progress_removals=\(current.progressRemovals) terminal_input_bytes_per_s=\(Self.rate(current.terminalInputBytes, seconds: seconds)) scroll_commits_per_s=\(Self.rate(current.scrollCommits, seconds: seconds)) size_updates_per_s=\(Self.rate(current.sizeUpdates, seconds: seconds)) layout_passes_per_s=\(Self.rate(current.layoutPasses, seconds: seconds))"
    )
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
}
