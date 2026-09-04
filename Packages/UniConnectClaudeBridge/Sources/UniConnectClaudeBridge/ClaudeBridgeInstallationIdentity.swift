import CryptoKit
import Foundation

/// Derives a stable, non-secret installation label without persisting another identifier.
public struct ClaudeBridgeInstallationIdentity: Sendable {
    /// Produces a namespaced hexadecimal label from application-owned key material.
    ///
    /// The digest cannot be used to recover the vault key and is safe to place in
    /// remote route paths. HMAC tokens remain separate random secrets.
    ///
    /// - Parameter keyMaterial: Stable app-owned random key bytes.
    /// - Returns: A 32-character lowercase hexadecimal installation label.
    public static func derive(from keyMaterial: Data) -> String {
        var input = Data("uniconnect-claude-bridge-installation-v1\0".utf8)
        input.append(keyMaterial)
        return SHA256.hash(data: input).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
