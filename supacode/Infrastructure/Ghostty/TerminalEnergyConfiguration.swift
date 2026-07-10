import Foundation

nonisolated enum TerminalEnergyConfiguration {
  static let defaultProgressThrottleMs = 50
  static let energyModeProgressThrottleMs = 250
  static let defaultUnfocusedFrameCapMs = 250

  static func isEnabled(
    _ name: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return false }
    switch value.lowercased() {
    case "0", "false", "no", "off":
      return false
    default:
      return true
    }
  }

  static func progressThrottleInterval(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    lowEnergyModeSetting: Bool = false
  ) -> Duration {
    let milliseconds = progressThrottleMilliseconds(
      environment: environment,
      lowEnergyModeSetting: lowEnergyModeSetting
    )
    return .milliseconds(milliseconds)
  }

  static func progressThrottleMilliseconds(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    lowEnergyModeSetting: Bool = false
  ) -> Int {
    if let override = positiveInt("SUPACODE_PROGRESS_THROTTLE_MS", environment: environment) {
      return override
    }
    // Either the persisted user setting or the env override enables energy mode.
    // The env var stays for headless benchmarking; the setting is the shipping UI.
    if lowEnergyModeSetting || isEnabled("SUPACODE_ENERGY_MODE", environment: environment) {
      return energyModeProgressThrottleMs
    }
    return defaultProgressThrottleMs
  }

  static func unfocusedFrameCapInterval(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Duration {
    .milliseconds(unfocusedFrameCapMilliseconds(environment: environment))
  }

  static func unfocusedFrameCapMilliseconds(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Int {
    positiveInt("SUPACODE_UNFOCUSED_FRAME_CAP_MS", environment: environment)
      ?? defaultUnfocusedFrameCapMs
  }

  static func renderStatsEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    isEnabled("SUPACODE_RENDER_STATS", environment: environment)
      || isEnabled("SUPACODE_ENERGY_DEBUG", environment: environment)
  }

  private static func positiveInt(_ name: String, environment: [String: String]) -> Int? {
    guard let rawValue = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
      let value = Int(rawValue),
      value > 0
    else { return nil }
    return value
  }
}
