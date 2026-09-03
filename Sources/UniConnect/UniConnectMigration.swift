import Foundation

/// One-time import of cmux's user settings so UniConnect starts with the same theme,
/// fonts and preferences while keeping its own identity (bundle id, folders, sockets).
/// Nothing in cmux's domain is ever modified.
enum UniConnectMigration {
    private static let flagKey = "uniconnect.migratedFromCmux"
    private static let cmuxBundleIdentifier = "com.cmuxterm.app"

    static func runIfNeeded() {
        guard UniConnectIdentity.isUniConnect else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: flagKey) {
            if let cmux = UserDefaults(suiteName: cmuxBundleIdentifier),
               let persisted = cmux.persistentDomain(forName: cmuxBundleIdentifier) {
                for (key, value) in persisted where !key.hasPrefix("SU") && defaults.object(forKey: key) == nil {
                    defaults.set(value, forKey: key)
                }
            }
            defaults.set(true, forKey: flagKey)
        }
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let bundleId = Bundle.main.bundleIdentifier else { return }
        let mine = appSupport.appendingPathComponent(bundleId, isDirectory: true)
        let theirs = appSupport.appendingPathComponent(cmuxBundleIdentifier, isDirectory: true)
        if !fm.fileExists(atPath: mine.path), fm.fileExists(atPath: theirs.path) {
            try? fm.copyItem(at: theirs, to: mine)
        }
    }
}
