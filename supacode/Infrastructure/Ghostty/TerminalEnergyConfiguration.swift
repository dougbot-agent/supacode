import Foundation

nonisolated enum TerminalEnergyConfiguration {
  static let defaultProgressThrottleMs = 50
  static let defaultFocusedFrameCapMs = 33
  static let energyModeFocusedFrameCapMs = 100
  static let energyModeProgressThrottleMs = energyModeFocusedFrameCapMs
  static let defaultUnfocusedFrameCapMs = 250
  static let defaultIdleQuietThresholdMs = 500
  static let energyModeIdleQuietFrameCapMs = 250

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
    if lowEnergyModeSetting || isEnabled("SUPACODE_ENERGY_MODE", environment: environment) {
      return energyModeProgressThrottleMs
    }
    return defaultProgressThrottleMs
  }

  static func focusedFrameCapInterval(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    lowEnergyModeSetting: Bool = false
  ) -> Duration? {
    guard let milliseconds = focusedFrameCapMilliseconds(
      environment: environment,
      lowEnergyModeSetting: lowEnergyModeSetting
    ) else { return nil }
    return .milliseconds(milliseconds)
  }

  static func focusedFrameCapMilliseconds(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    lowEnergyModeSetting: Bool = false
  ) -> Int? {
    if let override = positiveInt("SUPACODE_FOCUSED_FRAME_CAP_MS", environment: environment) {
      return override
    }
    if let override = positiveInt("SUPACODE_PROGRESS_THROTTLE_MS", environment: environment) {
      return override
    }
    // Either the persisted user setting or the env override enables energy mode.
    // The env var stays for headless benchmarking; the setting is the shipping UI.
    if focusedFrameCapState(environment: environment, lowEnergyModeSetting: lowEnergyModeSetting)
      == .lowEnergy
    {
      return energyModeFocusedFrameCapMs
    }
    return defaultFocusedFrameCapMs
  }

  static func focusedFrameCapState(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    lowEnergyModeSetting: Bool = false
  ) -> TerminalFocusedFrameCapState {
    if positiveInt("SUPACODE_FOCUSED_FRAME_CAP_MS", environment: environment) != nil {
      return .custom
    }
    if positiveInt("SUPACODE_PROGRESS_THROTTLE_MS", environment: environment) != nil {
      return .custom
    }
    if lowEnergyModeSetting || isEnabled("SUPACODE_ENERGY_MODE", environment: environment) {
      return .lowEnergy
    }
    return .default
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

  static func idleQuietThresholdMilliseconds(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Int {
    positiveInt("SUPACODE_IDLE_QUIET_THRESHOLD_MS", environment: environment)
      ?? defaultIdleQuietThresholdMs
  }

  static func idleQuietFrameCapMilliseconds(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    lowEnergyModeSetting: Bool = false
  ) -> Int? {
    if let override = positiveInt("SUPACODE_IDLE_QUIET_FRAME_CAP_MS", environment: environment) {
      return override
    }
    if lowEnergyModeSetting || isEnabled("SUPACODE_ENERGY_MODE", environment: environment) {
      return energyModeIdleQuietFrameCapMs
    }
    return nil
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

nonisolated enum TerminalFocusedFrameCapState: String, Equatable {
  case `default` = "focused_default_cap"
  case lowEnergy = "focused_low_energy_cap"
  case custom = "focused_custom_cap"
}

nonisolated enum TerminalPresentationSuspendState: String, Equatable {
  case visible = "none"
  case hidden = "hidden_minimized_or_occluded"

  var isSuspended: Bool {
    self != .visible
  }
}

nonisolated enum TerminalIdleQuietState: String, Equatable {
  case inactive
  case interactive
  case idleQuiet = "idle_quiet"
}
