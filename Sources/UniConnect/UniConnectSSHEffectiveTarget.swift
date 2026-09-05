import Foundation

/// The secret-free SSH endpoint produced after deterministic client configuration resolution.
struct UniConnectSSHEffectiveTarget: Equatable, Hashable, Sendable {
    let user: String
    let host: String
    let port: Int

    /// OpenSSH options that pin an alias-based invocation to this exact endpoint.
    var sshPinningOptions: [String] {
        [
            "-o", "CanonicalizeHostname=no",
            "-o", "HostName=\(host)",
            "-o", "User=\(user)",
            "-o", "Port=\(port)",
        ]
    }

    init?(user: String, host: String, port: Int) {
        guard let user = Self.normalizedUser(user),
              let host = Self.normalizedHost(host),
              (1...65_535).contains(port) else {
            return nil
        }
        self.user = user
        self.host = host
        self.port = port
    }

    static func normalizedHost(_ value: String) -> String? {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        if host.hasPrefix("[") || host.hasSuffix("]") {
            guard host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 else {
                return nil
            }
            host.removeFirst()
            host.removeLast()
        }
        while host.count > 1, host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty,
              host.utf8.count <= 1_024,
              !host.hasPrefix("-"),
              !host.contains("@"),
              !host.contains("/"),
              !host.contains("\\"),
              !host.contains("%"),
              !host.contains("$"),
              !host.unicodeScalars.contains(where: { scalar in
                  CharacterSet.whitespacesAndNewlines.contains(scalar)
                      || CharacterSet.controlCharacters.contains(scalar)
              }) else {
            return nil
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+:-"
        )
        guard host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return host.lowercased()
    }

    static func normalizedUser(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 256,
              !value.hasPrefix("-"),
              !value.contains("@"),
              !value.contains("%"),
              !value.contains("$"),
              !value.unicodeScalars.contains(where: { scalar in
                  CharacterSet.whitespacesAndNewlines.contains(scalar)
                      || CharacterSet.controlCharacters.contains(scalar)
              }) else {
            return nil
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains) ? value : nil
    }
}
