import CryptoKit
import Foundation

/// Verifies HMAC, freshness, route binding, replay protection, and completion coalescing.
actor ClaudeBridgeAuthenticator {
    private struct ReplayKey: Hashable {
        let routeID: UUID
        let eventID: String
    }

    private struct CompletionKey: Hashable {
        let routeID: UUID
        let sessionCorrelation: String
        let cwd: String
    }

    private struct CompletionStamp {
        let kind: ClaudeBridgeEventKind
        let occurredAt: Date
    }

    private let maximumAge: TimeInterval
    private let futureTolerance: TimeInterval
    private let replayRetention: TimeInterval
    private let completionCoalescingWindow: TimeInterval
    private let complementaryCompletionWindow: TimeInterval
    private let now: @Sendable () -> Date
    private var tokens: [UUID: Data] = [:]
    private var acceptedEventExpirations: [ReplayKey: Date] = [:]
    private var latestCompletionByKey: [CompletionKey: CompletionStamp] = [:]

    init(
        maximumAge: TimeInterval = 5 * 60,
        futureTolerance: TimeInterval = 30,
        replayRetention: TimeInterval = 24 * 60 * 60,
        completionCoalescingWindow: TimeInterval = 4,
        complementaryCompletionWindow: TimeInterval = 90,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.maximumAge = maximumAge
        self.futureTolerance = futureTolerance
        self.replayRetention = replayRetention
        self.completionCoalescingWindow = completionCoalescingWindow
        self.complementaryCompletionWindow = complementaryCompletionWindow
        self.now = now
    }

    func register(token: Data, for routeID: UUID) {
        guard token.count == 32 else { return }
        tokens[routeID] = token
    }

    func unregister(routeID: UUID) {
        tokens.removeValue(forKey: routeID)
        acceptedEventExpirations = acceptedEventExpirations.filter { $0.key.routeID != routeID }
        latestCompletionByKey = latestCompletionByKey.filter { $0.key.routeID != routeID }
    }

    func authenticate(
        _ message: ClaudeBridgeWireMessage,
        expectedRouteID: UUID
    ) -> Result<ClaudeBridgeEvent?, ClaudeBridgeAuthenticationRejection> {
        let currentDate = now()
        prune(at: currentDate)

        guard message.protocolName == ClaudeBridgeWireMessage.protocolName,
              message.version == ClaudeBridgeWireMessage.currentVersion,
              message.message == .hello || message.message == .event,
              let routeID = UUID(uuidString: message.routeID),
              routeID == expectedRouteID,
              let token = tokens[routeID],
              let signatureHex = normalizedHex(message.signature, exactLength: 64),
              let signature = data(hex: signatureHex),
              HMAC<SHA256>.isValidAuthenticationCode(
                  signature,
                  authenticating: message.canonicalAuthenticationData(),
                  using: SymmetricKey(data: token)
              ) else {
            return .failure(.unauthenticated)
        }

        guard let eventID = normalizedHex(message.eventID, exactLength: 64) else {
            return .failure(.malformed)
        }
        let replayKey = ReplayKey(routeID: routeID, eventID: eventID)
        if acceptedEventExpirations[replayKey] != nil {
            return .failure(.duplicate)
        }
        guard let occurredAt = freshDate(
            timestampMilliseconds: message.timestampMilliseconds,
            relativeTo: currentDate
        ) else {
            return .failure(.stale)
        }

        if message.message == .hello {
            guard message.eventType == nil,
                  message.sessionCorrelation == nil,
                  message.cwd == nil,
                  message.tmuxPane == nil,
                  message.token == nil,
                  message.integrationReady == nil,
                  message.integrationError == nil else {
                return .failure(.malformed)
            }
            acceptedEventExpirations[replayKey] = currentDate.addingTimeInterval(replayRetention)
            return .success(nil)
        }

        guard let kindRaw = message.eventType,
              let kind = ClaudeBridgeEventKind(rawValue: kindRaw),
              let sessionCorrelation = normalizedCorrelation(message.sessionCorrelation),
              let cwd = normalizedAbsolutePath(message.cwd),
              let tmuxPane = normalizedTmuxPane(message.tmuxPane),
              message.token == nil,
              message.integrationReady == nil,
              message.integrationError == nil else {
            return .failure(.malformed)
        }

        acceptedEventExpirations[replayKey] = currentDate.addingTimeInterval(replayRetention)
        if kind.isUserVisibleCompletion {
            let completionKey = CompletionKey(
                routeID: routeID,
                sessionCorrelation: sessionCorrelation,
                cwd: cwd
            )
            if let previous = latestCompletionByKey[completionKey] {
                let window = previous.kind == kind
                    ? completionCoalescingWindow
                    : complementaryCompletionWindow
                if abs(occurredAt.timeIntervalSince(previous.occurredAt)) <= window {
                    return .failure(.duplicate)
                }
            }
            latestCompletionByKey[completionKey] = CompletionStamp(kind: kind, occurredAt: occurredAt)
        }
        return .success(
            ClaudeBridgeEvent(
                id: eventID,
                occurredAt: occurredAt,
                kind: kind,
                sessionCorrelation: sessionCorrelation,
                cwd: cwd,
                tmuxPane: tmuxPane
            )
        )
    }

    func acceptEnrollment(
        _ message: ClaudeBridgeWireMessage,
        expectedRouteID: UUID
    ) -> Result<Void, ClaudeBridgeAuthenticationRejection> {
        let currentDate = now()
        prune(at: currentDate)
        guard message.protocolName == ClaudeBridgeWireMessage.protocolName,
              message.version == ClaudeBridgeWireMessage.currentVersion,
              message.message == .enroll,
              let routeID = UUID(uuidString: message.routeID),
              routeID == expectedRouteID,
              let eventID = normalizedHex(message.eventID, exactLength: 64) else {
            return .failure(.malformed)
        }
        let replayKey = ReplayKey(routeID: routeID, eventID: eventID)
        if acceptedEventExpirations[replayKey] != nil {
            return .failure(.duplicate)
        }
        guard freshDate(
            timestampMilliseconds: message.timestampMilliseconds,
            relativeTo: currentDate
        ) != nil else {
            return .failure(.stale)
        }
        acceptedEventExpirations[replayKey] = currentDate.addingTimeInterval(replayRetention)
        return .success(())
    }

    private func prune(at date: Date) {
        acceptedEventExpirations = acceptedEventExpirations.filter { $0.value > date }
        let retention = max(completionCoalescingWindow, complementaryCompletionWindow)
        latestCompletionByKey = latestCompletionByKey.filter {
            abs(date.timeIntervalSince($0.value.occurredAt)) <= retention
        }
    }

    private func freshDate(timestampMilliseconds: Int64, relativeTo currentDate: Date) -> Date? {
        guard timestampMilliseconds > 0 else { return nil }
        let eventDate = Date(timeIntervalSince1970: TimeInterval(timestampMilliseconds) / 1_000)
        let age = currentDate.timeIntervalSince(eventDate)
        guard age <= maximumAge, age >= -futureTolerance else { return nil }
        return eventDate
    }

    private func normalizedCorrelation(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 160, !trimmed.contains("\0") else {
            return nil
        }
        if UUID(uuidString: trimmed) != nil {
            return trimmed.lowercased()
        }
        return normalizedHex(trimmed, exactLength: 64)
    }

    private func normalizedAbsolutePath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.utf8.count <= 4_096,
              !trimmed.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return nil
        }
        return trimmed
    }

    private func normalizedTmuxPane(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^%[0-9]{1,12}$", options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    private func normalizedHex(_ value: String?, exactLength: Int) -> String? {
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

    private func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}
