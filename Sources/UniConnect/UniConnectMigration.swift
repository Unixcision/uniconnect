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
        // One-time, read-only copies of cmux's per-user files into UniConnect's own paths.
        let home = fm.homeDirectoryForCurrentUser
        let copies: [(URL, URL)] = [
            (home.appendingPathComponent(".cmuxterm/claude-hook-sessions.json"),
             home.appendingPathComponent(".uniconnect/claude-hook-sessions.json")),
            (home.appendingPathComponent(".config/cmux/cmux.json"),
             home.appendingPathComponent(".config/uniconnect/uniconnect.json")),
            (home.appendingPathComponent(".config/cmux/dock.json"),
             home.appendingPathComponent(".config/uniconnect/dock.json")),
        ]
        for (source, destination) in copies where !fm.fileExists(atPath: destination.path) && fm.fileExists(atPath: source.path) {
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.copyItem(at: source, to: destination)
        }
    }
}
