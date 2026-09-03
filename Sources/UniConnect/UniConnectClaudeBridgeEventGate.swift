import Foundation

/// Validates and deduplicates privacy-minimized Claude events arriving through an authenticated SSH relay.
@MainActor
final class UniConnectClaudeBridgeEventGate {
    struct Event: Equatable {
        enum Kind: String {
            case stop
            case idlePrompt = "idle_prompt"
        }

        let id: String
        let occurredAt: Date
        let kind: Kind
        let workspaceID: UUID
        let surfaceID: UUID
        let sessionID: UUID
        let cwd: String
        let hostID: String?
        let tmuxPane: String?
    }

    enum Rejection: Error, Equatable {
        case malformed
        case stale
        case duplicate
    }

    private let maximumAge: TimeInterval
    private let futureTolerance: TimeInterval
    private let retention: TimeInterval
    private let now: @Sendable () -> Date
    private var acceptedUntilByID: [String: Date] = [:]

    // Only assigns Sendable stored properties, so it is safe to call from a nonisolated
    // context (TerminalController's own init constructs this as a default parameter
    // value before any actor context is established).
    nonisolated init(
        maximumAge: TimeInterval = 5 * 60,
        futureTolerance: TimeInterval = 30,
        retention: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.maximumAge = maximumAge
        self.futureTolerance = futureTolerance
        self.retention = retention
        self.now = now
    }

    func accept(params: [String: Any]) -> Result<Event, Rejection> {
        let currentDate = now()
        acceptedUntilByID = acceptedUntilByID.filter { $0.value > currentDate }

        guard let id = Self.normalizedHex(params["event_id"] as? String, exactLength: 64),
              acceptedUntilByID[id] == nil,
              let timestampMilliseconds = Self.timestampMilliseconds(params["event_timestamp_ms"]),
              let kindRaw = params["event_type"] as? String,
              let kind = Event.Kind(rawValue: kindRaw),
              let workspaceID = Self.uuid(params["workspace_id"]),
              let surfaceID = Self.uuid(params["surface_id"]),
              let sessionID = Self.uuid(params["session_id"]),
              let cwd = Self.normalizedAbsolutePath(params["cwd"] as? String)
        else {
            if let id = Self.normalizedHex(params["event_id"] as? String, exactLength: 64),
               acceptedUntilByID[id] != nil {
                return .failure(.duplicate)
            }
            return .failure(.malformed)
        }

        let occurredAt = Date(timeIntervalSince1970: TimeInterval(timestampMilliseconds) / 1_000)
        let age = currentDate.timeIntervalSince(occurredAt)
        guard age <= maximumAge, age >= -futureTolerance else {
            return .failure(.stale)
        }

        let hostID = Self.normalizedIdentifier(params["host_id"] as? String, maximumLength: 160)
        let tmuxPane = Self.normalizedTmuxPane(params["tmux_pane"] as? String)
        let event = Event(
            id: id,
            occurredAt: occurredAt,
            kind: kind,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID,
            cwd: cwd,
            hostID: hostID,
            tmuxPane: tmuxPane
        )
        acceptedUntilByID[id] = currentDate.addingTimeInterval(retention)
        return .success(event)
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let string = value as? String else { return nil }
        return UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func timestampMilliseconds(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            return Int64(string)
        }
        return nil
    }

    private static func normalizedAbsolutePath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count <= 4_096, !trimmed.contains("\0") else {
            return nil
        }
        return trimmed
    }

    private static func normalizedHex(_ value: String?, exactLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == exactLength,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            return nil
        }
        return trimmed
    }

    private static func normalizedIdentifier(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength,
              trimmed.range(of: "^[A-Za-z0-9._:@-]+$", options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    private static func normalizedTmuxPane(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^%[0-9]{1,12}$", options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }
}
