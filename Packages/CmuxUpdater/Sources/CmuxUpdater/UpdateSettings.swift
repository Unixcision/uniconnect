public import Foundation

/// Applies Sparkle defaults without allowing an unconfigured build to enable networking.
///
/// The caller first validates the bundle's feed with ``UpdateFeedResolver`` and passes the
/// result to ``apply(to:updaterEnabled:)``. Disabled builds explicitly turn off checks and
/// downloads; configured Unixcision releases enable scheduled checks but keep installation
/// user-driven.
public struct UpdateSettings: Sendable {
    /// Sparkle's "automatically check for updates" key.
    public static let automaticChecksKey = "SUEnableAutomaticChecks"
    /// Sparkle's "automatically download/install updates" key.
    public static let automaticallyUpdateKey = "SUAutomaticallyUpdate"
    /// Sparkle's scheduled-check-interval key.
    public static let scheduledCheckIntervalKey = "SUScheduledCheckInterval"
    /// Sparkle's "send anonymous system profile" key.
    public static let sendProfileInfoKey = "SUSendProfileInfo"
    /// UniConnect's marker that the fail-closed updater migration has run.
    public static let migrationKey = "uniconnect.sparkle.feedAllowlistMigration.v3"

    /// The previous default scheduled-check interval (24h) upgraded by configured releases.
    public let previousDefaultScheduledCheckInterval: TimeInterval
    /// The scheduled-check interval configured releases register (1h by default).
    public let scheduledCheckInterval: TimeInterval

    /// Creates the settings policy.
    ///
    /// - Parameters:
    ///   - scheduledCheckInterval: How often an enabled release checks, in seconds. Defaults
    ///     to one hour.
    ///   - previousDefaultScheduledCheckInterval: The legacy interval upgraded when found.
    ///     Defaults to 24 hours.
    public init(scheduledCheckInterval: TimeInterval = 60 * 60,
                previousDefaultScheduledCheckInterval: TimeInterval = 60 * 60 * 24) {
        self.scheduledCheckInterval = scheduledCheckInterval
        self.previousDefaultScheduledCheckInterval = previousDefaultScheduledCheckInterval
    }

    /// Applies updater preferences for the validated build configuration.
    ///
    /// - Parameters:
    ///   - defaults: The preferences store Sparkle reads.
    ///   - updaterEnabled: `true` only when the bundle contains an allowlisted appcast URL.
    public func apply(to defaults: UserDefaults, updaterEnabled: Bool) {
        defaults.register(defaults: [
            Self.automaticChecksKey: updaterEnabled,
            Self.automaticallyUpdateKey: false,
            Self.scheduledCheckIntervalKey: scheduledCheckInterval,
            Self.sendProfileInfoKey: false,
        ])

        // These are security and privacy boundaries, not inherited preferences.
        defaults.set(updaterEnabled, forKey: Self.automaticChecksKey)
        defaults.set(false, forKey: Self.automaticallyUpdateKey)
        defaults.set(false, forKey: Self.sendProfileInfoKey)

        guard updaterEnabled else {
            defaults.set(true, forKey: Self.migrationKey)
            return
        }

        if let interval = defaults.object(forKey: Self.scheduledCheckIntervalKey) as? NSNumber {
            let currentInterval = interval.doubleValue
            if currentInterval <= 0 ||
                abs(currentInterval - previousDefaultScheduledCheckInterval) < 1 {
                defaults.set(scheduledCheckInterval, forKey: Self.scheduledCheckIntervalKey)
            }
        } else {
            defaults.set(scheduledCheckInterval, forKey: Self.scheduledCheckIntervalKey)
        }

        defaults.set(true, forKey: Self.migrationKey)
    }
}
