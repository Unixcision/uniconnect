import Foundation

/// Resolves bundle-isolated state and log locations for the Claude updater.
enum UniConnectClaudeUpdatePaths {
    static func directory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? UniConnectIdentity.releaseBundleIdentifier
    ) -> URL {
        let root = homeDirectory
            .appendingPathComponent(".uniconnect", isDirectory: true)
            .appendingPathComponent("claude-update", isDirectory: true)
        guard bundleIdentifier != UniConnectIdentity.releaseBundleIdentifier else {
            return root
        }
        return root
            .appendingPathComponent("development", isDirectory: true)
            .appendingPathComponent(safeBundleComponent(bundleIdentifier), isDirectory: true)
    }

    static func recoveryJournal(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? UniConnectIdentity.releaseBundleIdentifier
    ) -> URL {
        directory(homeDirectory: homeDirectory, bundleIdentifier: bundleIdentifier)
            .appendingPathComponent("recovery.json", isDirectory: false)
    }

    static func structuredLog(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? UniConnectIdentity.releaseBundleIdentifier
    ) -> URL {
        directory(homeDirectory: homeDirectory, bundleIdentifier: bundleIdentifier)
            .appendingPathComponent("events.jsonl", isDirectory: false)
    }

    private static func safeBundleComponent(_ bundleIdentifier: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = bundleIdentifier.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(scalars)).prefix(180)
        return result.isEmpty ? "unknown-build" : String(result)
    }
}
