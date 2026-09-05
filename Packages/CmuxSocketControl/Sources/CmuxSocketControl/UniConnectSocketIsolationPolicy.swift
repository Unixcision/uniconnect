internal import Foundation

/// Decides whether the UniConnect CLI may contact a requested control-socket endpoint.
///
/// The policy is intentionally pure: callers provide the environment and the CLI's
/// executable bundle identifier. This keeps socket isolation testable without opening
/// a socket or reading the user's filesystem.
public enum UniConnectSocketIsolationPolicy {
    /// The explicit opt-in required to contact an endpoint identified as belonging to
    /// another product namespace.
    public static let allowForeignSocketEnvironmentKey = "UNICONNECT_ALLOW_FOREIGN_SOCKET"

    /// Returns whether the UniConnect CLI may contact a control-socket endpoint.
    ///
    /// UniConnect endpoints and neutral custom endpoints are accepted only from a
    /// UniConnect CLI binary and a UniConnect (or absent) ambient app context. Paths
    /// carrying the inherited `cmux` namespace and contexts belonging to another app
    /// are rejected. A deliberate caller can opt in by setting
    /// `UNICONNECT_ALLOW_FOREIGN_SOCKET=1` for that single invocation.
    ///
    /// - Parameters:
    ///   - endpoint: Unix-domain socket path or authenticated loopback relay endpoint.
    ///   - executableBundleIdentifier: Bundle identifier enclosing the CLI binary.
    ///   - environment: Environment inherited by the CLI process.
    /// - Returns: `true` when connecting cannot accidentally cross the UniConnect
    ///   product boundary, or when the caller supplied the explicit opt-in.
    public static func permitsConnection(
        to endpoint: String,
        executableBundleIdentifier: String?,
        environment: [String: String]
    ) -> Bool {
        if environment[allowForeignSocketEnvironmentKey] == "1" {
            return true
        }

        guard isUniConnectBundleIdentifier(executableBundleIdentifier) else {
            return false
        }

        if let ambientBundleIdentifier = normalized(environment["CMUX_BUNDLE_ID"]),
           !isUniConnectBundleIdentifier(ambientBundleIdentifier) {
            return false
        }

        return !usesForeignCmuxNamespace(endpoint)
    }

    private static func isUniConnectBundleIdentifier(_ rawValue: String?) -> Bool {
        guard let bundleIdentifier = normalized(rawValue)?.lowercased() else {
            return false
        }
        return bundleIdentifier == "com.unixcision.uniconnect"
            || bundleIdentifier.hasPrefix("com.unixcision.uniconnect.")
    }

    private static func usesForeignCmuxNamespace(_ endpoint: String) -> Bool {
        guard let normalizedEndpoint = normalized(endpoint)?.lowercased() else {
            return true
        }

        // Authenticated relay endpoints are restricted to loopback by the transport.
        if normalizedEndpoint.hasPrefix("127.0.0.1:")
            || normalizedEndpoint.hasPrefix("localhost:") {
            return false
        }

        let standardizedPath = (normalizedEndpoint as NSString).standardizingPath
        let socketName = (standardizedPath as NSString).lastPathComponent
        if socketName == "cmux.sock" || socketName.hasPrefix("cmux-") {
            return true
        }

        let components = standardizedPath.split(separator: "/").map(String.init)
        if components.contains(".cmux") || components.contains("com.cmuxterm.app") {
            return true
        }

        let foreignParentPairs: Set<[String]> = [
            [".config", "cmux"],
            ["application support", "cmux"],
            ["caches", "cmux"],
            ["state", "cmux"],
        ]
        return components.indices.contains { index in
            guard index + 1 < components.count else {
                return false
            }
            return foreignParentPairs.contains([components[index], components[index + 1]])
        }
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
