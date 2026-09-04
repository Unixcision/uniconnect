import Foundation
import CryptoKit

/// Encodes updater host identity without embedding endpoints, usernames, or credentials.
enum UniConnectClaudeUpdateHostID {
    static let local = "local"
    private static let remotePrefix = "ssh-credential:"

    static func remote(credentialID: UUID) -> String {
        remotePrefix + credentialID.uuidString.lowercased()
    }

    static func remote(credentialID: UUID, endpointFingerprint: String) -> String {
        remote(credentialID: credentialID) + ":endpoint:" + endpointFingerprint
    }

    static func credentialID(from value: String) -> UUID? {
        guard value.hasPrefix(remotePrefix) else { return nil }
        let suffix = value.dropFirst(remotePrefix.count)
        let rawID = suffix.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first
        return rawID.flatMap { UUID(uuidString: String($0)) }
    }

    static func endpointFingerprint(from value: String) -> String? {
        guard let marker = value.range(of: ":endpoint:") else { return nil }
        let fingerprint = String(value[marker.upperBound...])
        guard fingerprint.count == 24,
              fingerprint.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            return nil
        }
        return fingerprint
    }

    static func endpointFingerprint(for session: DetectedSSHSession) -> String {
        let normalized = [
            session.destination.lowercased(),
            String(session.port ?? 22),
            session.jumpHost?.lowercased() ?? "",
        ].joined(separator: "\0")
        return SHA256.hash(data: Data(normalized.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
