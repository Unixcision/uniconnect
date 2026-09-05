import CryptoKit
import Foundation

/// A host-local terminal identity shared by desktop and remote clients, not an agent resume request.
struct UniConnectLocalTmuxBinding: Codable, Equatable, Hashable, Sendable {
    let name: String
    let socketName: String

    init?(name: String, socketName: String) {
        guard !name.contains("."), Self.isValidName(name, maximumLength: 80),
              Self.isValidName(socketName, maximumLength: 48) else { return nil }
        self.name = name
        self.socketName = socketName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let socketName = try container.decode(String.self, forKey: .socketName)
        guard let binding = Self(name: name, socketName: socketName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container,
                debugDescription: "Invalid host-local tmux identity"
            )
        }
        self = binding
    }

    /// New windows opt into tmux explicitly; decoding an old PTY never invents a binding.
    static func newWindow(panelID: UUID, bundleIdentifier: String) -> Self {
        let socketName: String
        if bundleIdentifier == "com.unixcision.uniconnect" {
            socketName = "uniconnect-local"
        } else {
            // A short deterministic namespace keeps tagged builds out of the real desktop server.
            let digest = SHA256.hash(data: Data(bundleIdentifier.utf8))
                .prefix(8).map { String(format: "%02x", $0) }.joined()
            socketName = "uniconnect-local-\(digest)"
        }
        return Self(
            name: "uc-" + panelID.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            socketName: socketName
        )!
    }

    private static func isValidName(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumLength
            && value.first != "-" && value.first != "."
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }
    }
}
