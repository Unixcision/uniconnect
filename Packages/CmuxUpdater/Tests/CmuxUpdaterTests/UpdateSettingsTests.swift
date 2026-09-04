import Foundation
import Testing
@testable import CmuxUpdater

@Suite struct UpdateSettingsTests {
    @Test func unconfiguredBuildForcesChecksAndDownloadsOff() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: UpdateSettings.automaticChecksKey)
        defaults.set(true, forKey: UpdateSettings.automaticallyUpdateKey)

        UpdateSettings().apply(to: defaults, updaterEnabled: false)

        #expect(!defaults.bool(forKey: UpdateSettings.automaticChecksKey))
        #expect(!defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
        #expect(!defaults.bool(forKey: UpdateSettings.sendProfileInfoKey))
    }

    @Test func allowlistedReleaseEnablesChecksButNotAutomaticInstallation() {
        let defaults = makeDefaults()

        UpdateSettings().apply(to: defaults, updaterEnabled: true)

        #expect(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
        #expect(!defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
        #expect(!defaults.bool(forKey: UpdateSettings.sendProfileInfoKey))
        #expect(
            defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey)
                == UpdateSettings().scheduledCheckInterval
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "UpdateSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
