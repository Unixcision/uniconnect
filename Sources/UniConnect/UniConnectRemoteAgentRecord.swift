import CMUXAgentLaunch
import Foundation

/// The agent a remote (SSH) tmux window runs, as the probe last saw it, persisted in the panel.
///
/// It is the SSH counterpart of ``UniConnectLocalWindowRecord``'s conversations: which provider,
/// which conversation, in which folder and as which user, plus an append-only history (≤ 32).
/// Only what the probe verified enters here; the resume command is always derived, never stored.
///
/// ```json
/// {"version":1,"provider":"claude","sessionID":"473ed1de-…","workingDirectory":"/root/xunis",
///  "asRoot":true,"tmuxSocket":"default","runtimeState":"agent","source":"ficha",
///  "observedAt":1790253004.0,"history":[…]}
/// ```
struct UniConnectRemoteAgentRecord: Codable, Equatable, Sendable {
    /// Whether the window was last seen running its agent or back at a shell.
    enum RuntimeState: String, Codable, Sendable {
        case agent
        case shell
    }

    /// One conversation this window has run, oldest first.
    struct HistoryEntry: Codable, Equatable, Sendable {
        let provider: String
        let sessionID: String
        let workingDirectory: String?
        let firstSeenAt: TimeInterval
        private(set) var lastSeenAt: TimeInterval

        init(provider: String, sessionID: String, workingDirectory: String?, firstSeenAt: TimeInterval, lastSeenAt: TimeInterval) {
            self.provider = provider
            self.sessionID = sessionID
            self.workingDirectory = workingDirectory
            self.firstSeenAt = firstSeenAt
            self.lastSeenAt = lastSeenAt
        }

        fileprivate mutating func touch(_ timestamp: TimeInterval) {
            lastSeenAt = max(lastSeenAt, timestamp)
        }
    }

    /// One verified observation of the window's agent.
    struct Observation: Equatable, Sendable {
        let provider: String
        let sessionID: String
        let workingDirectory: String?
        let asRoot: Bool?
        let source: String
    }

    static let currentVersion = 1
    static let maximumHistory = 32
    static let maximumWorkingDirectoryUTF8Bytes = 4 * 1_024

    private(set) var version: Int
    private(set) var provider: String
    private(set) var sessionID: String?
    private(set) var workingDirectory: String?
    private(set) var asRoot: Bool?
    let tmuxSocket: String
    private(set) var runtimeState: RuntimeState
    private(set) var source: String?
    private(set) var observedAt: TimeInterval
    private(set) var history: [HistoryEntry]

    /// Starts a record from a first verified observation.
    init?(observing observation: Observation, tmuxSocket: String, at timestamp: TimeInterval) {
        guard Self.isValid(observation), Self.isValidSocket(tmuxSocket), timestamp.isFinite else { return nil }
        version = Self.currentVersion
        provider = observation.provider
        sessionID = observation.sessionID
        workingDirectory = observation.workingDirectory
        asRoot = observation.asRoot
        self.tmuxSocket = tmuxSocket
        runtimeState = .agent
        source = observation.source
        observedAt = timestamp
        history = [HistoryEntry(
            provider: observation.provider,
            sessionID: observation.sessionID,
            workingDirectory: observation.workingDirectory,
            firstSeenAt: timestamp,
            lastSeenAt: timestamp
        )]
    }

    private enum CodingKeys: String, CodingKey {
        case version, provider, sessionID, workingDirectory, asRoot, tmuxSocket, runtimeState, source, observedAt, history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard decodedVersion == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container,
                debugDescription: "Unsupported UniConnect remote-agent version \(decodedVersion)"
            )
        }
        version = decodedVersion
        provider = try container.decode(String.self, forKey: .provider)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        asRoot = try container.decodeIfPresent(Bool.self, forKey: .asRoot)
        tmuxSocket = try container.decode(String.self, forKey: .tmuxSocket)
        runtimeState = try container.decode(RuntimeState.self, forKey: .runtimeState)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        observedAt = try container.decode(TimeInterval.self, forKey: .observedAt)
        history = try container.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        guard Self.isValidProvider(provider), Self.isValidSocket(tmuxSocket), observedAt.isFinite,
              sessionID.map(AgentNoPromptPolicy.isValidSessionID) ?? true,
              workingDirectory.map(Self.isValidDirectory) ?? true,
              history.count <= Self.maximumHistory,
              history.allSatisfy({
                  Self.isValidProvider($0.provider) && AgentNoPromptPolicy.isValidSessionID($0.sessionID)
                      && ($0.workingDirectory.map(Self.isValidDirectory) ?? true)
              }),
              runtimeState == .shell || sessionID != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionID, in: container,
                debugDescription: "Invalid UniConnect remote-agent record"
            )
        }
    }

    /// Records a verified agent observation. A new conversation becomes the active one and enters
    /// the history; the previous one stays there.
    ///
    /// - Returns: Whether anything worth saving changed (a repeat of the same state is not).
    @discardableResult
    mutating func observe(_ observation: Observation, at timestamp: TimeInterval) -> Bool {
        guard Self.isValid(observation), timestamp.isFinite else { return false }
        let changed = runtimeState != .agent
            || provider != observation.provider
            || sessionID?.lowercased() != observation.sessionID.lowercased()
            || workingDirectory != observation.workingDirectory
            || asRoot != observation.asRoot
            || source != observation.source
        guard changed else { return false }
        provider = observation.provider
        sessionID = observation.sessionID
        workingDirectory = observation.workingDirectory
        asRoot = observation.asRoot
        source = observation.source
        runtimeState = .agent
        observedAt = max(observedAt, timestamp)
        if let index = history.firstIndex(where: {
            $0.provider == observation.provider && $0.sessionID.lowercased() == observation.sessionID.lowercased()
        }) {
            history[index].touch(timestamp)
        } else {
            history.append(HistoryEntry(
                provider: observation.provider,
                sessionID: observation.sessionID,
                workingDirectory: observation.workingDirectory,
                firstSeenAt: timestamp,
                lastSeenAt: timestamp
            ))
            if history.count > Self.maximumHistory {
                history.removeFirst(history.count - Self.maximumHistory)
            }
        }
        return true
    }

    /// Records that the window is back at a shell. The last conversation is kept (and its history),
    /// but it is no longer resumed automatically.
    ///
    /// - Returns: Whether the state changed.
    @discardableResult
    mutating func observeShell(at timestamp: TimeInterval) -> Bool {
        guard runtimeState != .shell, timestamp.isFinite else { return false }
        runtimeState = .shell
        observedAt = max(observedAt, timestamp)
        if let sessionID, let index = history.lastIndex(where: { $0.sessionID == sessionID }) {
            history[index].touch(timestamp)
        }
        return true
    }

    /// The provider in `RestorableAgentKind` terms, for local display names and policies.
    var restorableKind: RestorableAgentKind? {
        RestorableAgentKind(rawValue: provider == "agy" ? "antigravity" : provider)
    }

    private static func isValid(_ observation: Observation) -> Bool {
        isValidProvider(observation.provider)
            && AgentNoPromptPolicy.isValidSessionID(observation.sessionID)
            && (observation.workingDirectory.map(isValidDirectory) ?? true)
            && ["ficha", "rollout", "argv", "hook", "manifiesto", "registro"].contains(observation.source)
    }

    private static func isValidProvider(_ provider: String) -> Bool {
        provider.range(of: #"^[a-z][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
    }

    private static func isValidSocket(_ socket: String) -> Bool {
        socket.range(of: #"^[A-Za-z0-9_.-]{1,64}$"#, options: .regularExpression) != nil
    }

    private static func isValidDirectory(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.utf8.count <= maximumWorkingDirectoryUTF8Bytes
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

extension Notification.Name {
    /// Posted with the workspace id as `object` when a remote window's verified agent changes.
    static let uniConnectRemoteAgentChanged = Notification.Name(
        "com.unixcision.uniconnect.remote-agent.changed"
    )
}
