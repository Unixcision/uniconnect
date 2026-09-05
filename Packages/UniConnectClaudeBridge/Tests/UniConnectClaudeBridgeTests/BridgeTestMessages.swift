import CryptoKit
import Foundation
@testable import UniConnectClaudeBridge

enum BridgeTestMessages {
    static func route(
        id: UUID = UUID(),
        workspaceID: UUID = UUID(),
        surfaceID: UUID? = nil,
        credentialID: UUID = UUID(),
        host: String = "test-host",
        tmuxSession: String = "uc-test"
    ) -> ClaudeBridgeRoute {
        ClaudeBridgeRoute(
            id: id,
            workspaceID: workspaceID,
            surfaceID: surfaceID ?? id,
            credentialID: credentialID,
            hostLabel: host,
            workspaceName: "Test box",
            windowName: "Test window",
            tmuxSession: tmuxSession
        )
    }

    static func enrollment(
        routeID: UUID,
        token: Data,
        timestamp: Date,
        eventID: String = String(repeating: "a", count: 64),
        ready: Bool = true,
        error: String? = nil,
        connectionID: UUID? = nil
    ) -> ClaudeBridgeWireMessage {
        ClaudeBridgeWireMessage(
            protocolName: ClaudeBridgeWireMessage.protocolName,
            version: ClaudeBridgeWireMessage.currentVersion,
            message: .enroll,
            routeID: routeID.uuidString.lowercased(),
            eventID: eventID,
            timestampMilliseconds: Int64(timestamp.timeIntervalSince1970 * 1_000),
            eventType: nil,
            sessionCorrelation: nil,
            cwd: nil,
            tmuxPane: nil,
            token: token.base64EncodedString(),
            signature: nil,
            integrationReady: ready,
            integrationError: error,
            connectionID: connectionID?.uuidString.lowercased()
        )
    }

    static func event(
        routeID: UUID,
        token: Data,
        timestamp: Date,
        eventID: String = String(repeating: "b", count: 64),
        kind: ClaudeBridgeEventKind = .stop,
        sessionID: String = "11111111-2222-4333-8444-555555555555",
        cwd: String = "/srv/test",
        pane: String = "%7",
        connectionID: UUID? = nil
    ) -> ClaudeBridgeWireMessage {
        let unsigned = ClaudeBridgeWireMessage(
            protocolName: ClaudeBridgeWireMessage.protocolName,
            version: ClaudeBridgeWireMessage.currentVersion,
            message: .event,
            routeID: routeID.uuidString.lowercased(),
            eventID: eventID,
            timestampMilliseconds: Int64(timestamp.timeIntervalSince1970 * 1_000),
            eventType: kind.rawValue,
            sessionCorrelation: sessionID,
            cwd: cwd,
            tmuxPane: pane,
            token: nil,
            signature: nil,
            integrationReady: nil,
            integrationError: nil,
            connectionID: connectionID?.uuidString.lowercased()
        )
        let signature = HMAC<SHA256>.authenticationCode(
            for: unsigned.canonicalAuthenticationData(),
            using: SymmetricKey(data: token)
        ).map { String(format: "%02x", $0) }.joined()
        return ClaudeBridgeWireMessage(
            protocolName: unsigned.protocolName,
            version: unsigned.version,
            message: unsigned.message,
            routeID: unsigned.routeID,
            eventID: unsigned.eventID,
            timestampMilliseconds: unsigned.timestampMilliseconds,
            eventType: unsigned.eventType,
            sessionCorrelation: unsigned.sessionCorrelation,
            cwd: unsigned.cwd,
            tmuxPane: unsigned.tmuxPane,
            token: nil,
            signature: signature,
            integrationReady: nil,
            integrationError: nil,
            connectionID: unsigned.connectionID
        )
    }

    static func hello(
        routeID: UUID,
        token: Data,
        timestamp: Date,
        eventID: String = String(repeating: "f", count: 64),
        connectionID: UUID? = nil
    ) -> ClaudeBridgeWireMessage {
        let unsigned = ClaudeBridgeWireMessage(
            protocolName: ClaudeBridgeWireMessage.protocolName,
            version: ClaudeBridgeWireMessage.currentVersion,
            message: .hello,
            routeID: routeID.uuidString.lowercased(),
            eventID: eventID,
            timestampMilliseconds: Int64(timestamp.timeIntervalSince1970 * 1_000),
            eventType: nil,
            sessionCorrelation: nil,
            cwd: nil,
            tmuxPane: nil,
            token: nil,
            signature: nil,
            integrationReady: nil,
            integrationError: nil,
            connectionID: connectionID?.uuidString.lowercased()
        )
        let signature = HMAC<SHA256>.authenticationCode(
            for: unsigned.canonicalAuthenticationData(),
            using: SymmetricKey(data: token)
        ).map { String(format: "%02x", $0) }.joined()
        return ClaudeBridgeWireMessage(
            protocolName: unsigned.protocolName,
            version: unsigned.version,
            message: unsigned.message,
            routeID: unsigned.routeID,
            eventID: unsigned.eventID,
            timestampMilliseconds: unsigned.timestampMilliseconds,
            eventType: nil,
            sessionCorrelation: nil,
            cwd: nil,
            tmuxPane: nil,
            token: nil,
            signature: signature,
            integrationReady: nil,
            integrationError: nil,
            connectionID: unsigned.connectionID
        )
    }

    static func data(_ message: ClaudeBridgeWireMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(message)
    }
}
