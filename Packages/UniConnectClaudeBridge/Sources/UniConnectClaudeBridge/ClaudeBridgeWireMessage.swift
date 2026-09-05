import Foundation

/// The bounded wire envelope exchanged only through the SSH reverse-forward.
struct ClaudeBridgeWireMessage: Codable, Sendable, Equatable {
    enum MessageKind: String, Codable, Sendable {
        case enroll
        case hello
        case event
    }

    let protocolName: String
    let version: Int
    let message: MessageKind
    let routeID: String
    let eventID: String
    let timestampMilliseconds: Int64
    let eventType: String?
    let sessionCorrelation: String?
    let cwd: String?
    let tmuxPane: String?
    let token: String?
    let signature: String?
    let integrationReady: Bool?
    let integrationError: String?
    var connectionID: String? = nil

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case version
        case message
        case routeID = "route_id"
        case eventID = "event_id"
        case timestampMilliseconds = "timestamp_ms"
        case eventType = "event_type"
        case sessionCorrelation = "session_id"
        case cwd
        case tmuxPane = "tmux_pane"
        case token
        case signature
        case integrationReady = "integration_ready"
        case integrationError = "integration_error"
        case connectionID = "connection_id"
    }

    static let protocolName = "uniconnect-claude-bridge"
    static let currentVersion = 1

    func canonicalAuthenticationData() -> Data {
        var fields = [
            protocolName,
            String(version),
            message.rawValue,
            routeID.lowercased(),
            eventID.lowercased(),
            String(timestampMilliseconds),
            eventType ?? "",
            Self.base64(sessionCorrelation ?? ""),
            Self.base64(cwd ?? ""),
            tmuxPane ?? "",
            integrationReady.map { $0 ? "1" : "0" } ?? "",
            integrationError ?? "",
        ]
        // Legacy live routes keep their original signature format during migration.
        if let connectionID { fields.append(connectionID.lowercased()) }
        return Data(fields.joined(separator: "\n").utf8)
    }

    private static func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}
