import CryptoKit
import Foundation

/// Derives a stable non-secret installation identifier without logging a user path.
enum UniConnectClaudeInstallationIdentity {
    static func identifier(executablePath: String) -> String {
        let standardized = (executablePath as NSString).standardizingPath
        let digest = SHA256.hash(data: Data(standardized.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
