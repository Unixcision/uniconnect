import Foundation

/// The output of `agent_probe.py`, version 1, as fixed by `contracts/agent-tree-v1/sonda-salida.json`.
///
/// The probe runs on the host that owns the tmux server (a VPS over SSH, or Linux locally) and
/// reports, per pane, which agent runs there. It is read-only on both sides. A report with
/// ``error`` set, or a version other than 1, never changes anything stored.
///
/// The contract shape is `{version, host, uid, user, socket, error, panes: [...]}`. Reports that
/// group panes under `sessions: [{name, session_id, pane_id, pane_pid, reason, agent, panes}]`
/// (an earlier draft of the probe) decode to the same panes, so both ends can roll out in any order.
///
/// ```swift
/// let report = try JSONDecoder().decode(AgentProbeReport.self, from: output)
/// report.session(named: "claudebets")?.agent?.sessionID
/// ```
public struct AgentProbeReport: Sendable, Equatable, Decodable {
    /// The agent the probe found in one pane.
    public struct Agent: Sendable, Equatable, Decodable {
        /// `claude`, `codex`, `agy`, `grok` or another catalogue id.
        public let provider: String
        /// The conversation id, or `nil` when the agent has none yet (`sin_id`).
        public let sessionID: String?
        /// The resolved folder the agent works in.
        public let workingDirectory: String?
        /// Whether the agent's root process runs as uid 0.
        public let asRoot: Bool?
        /// `ficha`, `rollout` or `argv`; `nil` without an id.
        public let source: String?
        /// The agent's root pid on the remote host.
        public let processID: Int?
        /// Claude's reported status, when its session file has one.
        public let status: String?
        /// The agent version, when its session file has one.
        public let version: String?

        private enum CodingKeys: String, CodingKey {
            case provider, cwd, source, pid, status, version
            case sessionID = "session_id"
            case asRoot = "as_root"
        }

        /// Creates an agent entry, for tests.
        public init(
            provider: String, sessionID: String?, workingDirectory: String?, asRoot: Bool?,
            source: String?, processID: Int? = nil, status: String? = nil, version: String? = nil
        ) {
            self.provider = provider
            self.sessionID = sessionID
            self.workingDirectory = workingDirectory
            self.asRoot = asRoot
            self.source = source
            self.processID = processID
            self.status = status
            self.version = version
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try container.decode(String.self, forKey: .provider)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
                .flatMap { AgentNoPromptPolicy.isValidSessionID($0) ? $0 : nil }
            workingDirectory = try container.decodeIfPresent(String.self, forKey: .cwd)
                .flatMap { $0.hasPrefix("/") ? $0 : nil }
            asRoot = try? container.decodeIfPresent(Bool.self, forKey: .asRoot)
            source = try? container.decodeIfPresent(String.self, forKey: .source)
            processID = try? container.decodeIfPresent(Int.self, forKey: .pid)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            version = try? container.decodeIfPresent(String.self, forKey: .version)
        }
    }

    /// One tmux pane as the probe saw it.
    public struct Pane: Sendable, Equatable {
        /// The tmux session name.
        public let session: String
        /// The live tmux session id (`$N`); tmux renumbers it when its server restarts.
        public let sessionID: String?
        /// The live pane id (`%N`).
        public let paneID: String?
        /// Whether the pane's process has exited; a dead pane is not probed.
        public let isDead: Bool
        /// `#{pane_current_path}`.
        public let currentPath: String?
        /// The agent in the pane, or `nil`.
        public let agent: Agent?
        /// `sin_id`, `sin_ia`, `identidad_ambigua`, or `nil`.
        public let cause: String?

        /// Creates a pane entry, for tests.
        public init(
            session: String, sessionID: String?, paneID: String?, isDead: Bool = false,
            currentPath: String? = nil, agent: Agent?, cause: String?
        ) {
            self.session = session
            self.sessionID = sessionID
            self.paneID = paneID
            self.isDead = isDead
            self.currentPath = currentPath
            self.agent = agent
            self.cause = cause
        }

        /// Whether this pane holds an agent, identified or not, or more than one.
        var holdsAgent: Bool {
            agent != nil || cause == "identidad_ambigua"
        }
    }

    /// What one tmux session holds once its panes are combined.
    public struct Session: Sendable, Equatable {
        /// The tmux session name.
        public let name: String
        /// The live tmux session id (`$N`).
        public let sessionID: String?
        /// The live id of the pane that decided (`%N`).
        public let paneID: String?
        /// The single agent, or `nil`.
        public let agent: Agent?
        /// `sin_id`, `sin_ia`, `identidad_ambigua`, or `nil` when an agent was identified or
        /// nothing could be probed.
        public let cause: String?
    }

    /// Always 1; any other version fails to decode.
    public let version: Int
    /// The tmux socket that was probed (`default` is the default server).
    public let socket: String?
    /// The uid the probe ran as.
    public let uid: Int?
    /// The user the probe ran as.
    public let user: String?
    /// `sin_tmux`, `sin_servidor`, `fallo_tmux` or `nil`. With an error, nothing stored is touched.
    public let error: String?
    /// Every pane the probe read.
    public let panes: [Pane]

    /// Errors a report can fail to decode with.
    public enum ReportError: Error, Equatable {
        /// The report is not version 1.
        case unsupportedVersion(Int)
    }

    /// Creates a report, for tests.
    public init(version: Int = 1, socket: String?, uid: Int?, user: String?, error: String?, panes: [Pane]) {
        self.version = version
        self.socket = socket
        self.uid = uid
        self.user = user
        self.error = error
        self.panes = panes
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        version = try container.decode(Int.self, forKey: Key("version"))
        guard version == 1 else { throw ReportError.unsupportedVersion(version) }
        socket = try? container.decodeIfPresent(String.self, forKey: Key("socket"))
        var uid = try? container.decodeIfPresent(Int.self, forKey: Key("uid"))
        if uid == nil, let host = try? container.nestedContainer(keyedBy: Key.self, forKey: Key("host")) {
            uid = try? host.decodeIfPresent(Int.self, forKey: Key("uid"))
        }
        self.uid = uid
        user = try? container.decodeIfPresent(String.self, forKey: Key("user"))
        error = try? container.decodeIfPresent(String.self, forKey: Key("error"))
        if container.contains(Key("panes")) {
            var list = try container.nestedUnkeyedContainer(forKey: Key("panes"))
            var panes: [Pane] = []
            while !list.isAtEnd {
                let pane = try list.nestedContainer(keyedBy: Key.self)
                panes.append(try Self.pane(pane, session: nil))
            }
            self.panes = panes
        } else if container.contains(Key("sessions")) {
            var list = try container.nestedUnkeyedContainer(forKey: Key("sessions"))
            var panes: [Pane] = []
            while !list.isAtEnd {
                let session = try list.nestedContainer(keyedBy: Key.self)
                let name = try session.decode(String.self, forKey: Key("name"))
                panes.append(try Self.pane(session, session: name))
            }
            self.panes = panes
        } else {
            panes = []
        }
    }

    private static func pane(_ container: KeyedDecodingContainer<Key>, session name: String?) throws -> Pane {
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = try? container.decodeIfPresent(String.self, forKey: Key(key)) { return value }
            }
            return nil
        }
        let session = try name ?? container.decode(String.self, forKey: Key("session"))
        let dead = (try? container.decodeIfPresent(Bool.self, forKey: Key("pane_dead")))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: Key("dead")))
            ?? nil
        return Pane(
            session: session,
            sessionID: string("session_id"),
            paneID: string("pane_id"),
            isDead: dead ?? false,
            currentPath: string("pane_current_path", "current_path"),
            agent: try container.decodeIfPresent(Agent.self, forKey: Key("agent")),
            cause: string("cause", "reason")
        )
    }

    /// Combines the panes of one tmux session with the contract's rule.
    ///
    /// The single pane holding an agent decides; agents in more than one pane make the session
    /// `identidad_ambigua`; live panes without an agent make it `sin_ia`.
    ///
    /// - Parameter name: The tmux session name.
    /// - Returns: The session, or `nil` when the report has no live pane for it or carries an error.
    public func session(named name: String) -> Session? {
        guard error == nil else { return nil }
        let members = panes.filter { $0.session == name }
        let live = members.filter { !$0.isDead }
        guard let first = live.first else { return nil }
        let holders = live.filter(\.holdsAgent)
        if holders.count > 1 {
            return Session(name: name, sessionID: first.sessionID, paneID: nil, agent: nil, cause: "identidad_ambigua")
        }
        if let holder = holders.first {
            return Session(name: name, sessionID: holder.sessionID, paneID: holder.paneID, agent: holder.agent, cause: holder.cause)
        }
        return Session(name: name, sessionID: first.sessionID, paneID: first.paneID, agent: nil, cause: "sin_ia")
    }
}
