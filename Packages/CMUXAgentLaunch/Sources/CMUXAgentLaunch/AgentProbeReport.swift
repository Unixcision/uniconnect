import Foundation

/// The output of `agent_probe.py`, version 1, as fixed by `contracts/agent-tree-v1/sonda-salida.json`.
///
/// The probe runs on the host that owns the tmux server (a VPS over SSH, or Linux locally) and
/// reports, per tmux session, which agent runs there; the probe already combines the panes of each
/// session. It is read-only on both sides. A report with ``error`` set never changes anything
/// stored, and ``Session/effect`` says what a reader may do with each session
/// (`contracts/agent-tree-v1/sonda-lectura.json`).
///
/// Shape: `{version, checked_at, socket, host: {hostname, uid, platform} | null, server, error,
/// truncated, sessions: [{name, session_id, pane_id, pane_pid, live, reason, agent, panes: [...]}]}`.
///
/// ```swift
/// let report = try JSONDecoder().decode(AgentProbeReport.self, from: output)
/// report.session(named: "claudebets")?.agent?.sessionID
/// ```
public struct AgentProbeReport: Sendable, Equatable, Decodable {
    /// The agent the probe found in one session.
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
        /// The process start time Claude wrote in its session file, when it has one.
        public let processStart: String?

        private enum CodingKeys: String, CodingKey {
            case provider, cwd, source, pid, status, version
            case sessionID = "session_id"
            case asRoot = "as_root"
            case processStart = "proc_start"
        }

        /// Creates an agent entry, for tests.
        ///
        /// - Parameters:
        ///   - provider: The wire provider id.
        ///   - sessionID: The conversation id, `nil` for `sin_id`.
        ///   - workingDirectory: The resolved folder.
        ///   - asRoot: Whether the root process runs as uid 0.
        ///   - source: Where the id was read from.
        ///   - processID: The agent's root pid.
        ///   - status: Claude's status.
        ///   - version: The agent version.
        ///   - processStart: Claude's process start time.
        public init(
            provider: String, sessionID: String?, workingDirectory: String?, asRoot: Bool?,
            source: String?, processID: Int? = nil, status: String? = nil, version: String? = nil,
            processStart: String? = nil
        ) {
            self.provider = provider
            self.sessionID = sessionID
            self.workingDirectory = workingDirectory
            self.asRoot = asRoot
            self.source = source
            self.processID = processID
            self.status = status
            self.version = version
            self.processStart = processStart
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try container.decode(String.self, forKey: .provider)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
                .flatMap { AgentNoPromptPolicy.isValidSessionID($0) ? $0 : nil }
            workingDirectory = try container.decodeIfPresent(String.self, forKey: .cwd)
                .flatMap { $0.hasPrefix("/") ? $0 : nil }
            asRoot = (try? container.decodeIfPresent(Bool.self, forKey: .asRoot)) ?? nil
            source = (try? container.decodeIfPresent(String.self, forKey: .source)) ?? nil
            processID = (try? container.decodeIfPresent(Int.self, forKey: .pid)) ?? nil
            status = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? nil
            version = (try? container.decodeIfPresent(String.self, forKey: .version)) ?? nil
            processStart = (try? container.decodeIfPresent(String.self, forKey: .processStart)) ?? nil
        }
    }

    /// One tmux pane of a session, as the probe listed it.
    public struct Pane: Sendable, Equatable, Decodable {
        /// The live pane id (`%N`).
        public let paneID: String?
        /// The window the pane belongs to.
        public let windowIndex: Int?
        /// `#{pane_pid}`: the pane's shell.
        public let panePID: Int?
        /// Whether the pane's process has exited (`remain-on-exit`).
        public let isDead: Bool
        /// `#{pane_current_path}`.
        public let currentPath: String?
        /// `#{pane_current_command}`.
        public let currentCommand: String?

        private enum CodingKeys: String, CodingKey {
            case dead
            case paneID = "pane_id"
            case windowIndex = "window_index"
            case panePID = "pane_pid"
            case currentPath = "current_path"
            case currentCommand = "current_command"
        }

        /// Creates a pane entry, for tests.
        ///
        /// - Parameters:
        ///   - paneID: The pane id.
        ///   - windowIndex: The window index.
        ///   - panePID: The pane's shell pid.
        ///   - isDead: Whether the pane is dead.
        ///   - currentPath: The pane's folder.
        ///   - currentCommand: The pane's foreground command.
        public init(
            paneID: String?, windowIndex: Int? = nil, panePID: Int? = nil, isDead: Bool = false,
            currentPath: String? = nil, currentCommand: String? = nil
        ) {
            self.paneID = paneID
            self.windowIndex = windowIndex
            self.panePID = panePID
            self.isDead = isDead
            self.currentPath = currentPath
            self.currentCommand = currentCommand
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneID = (try? container.decodeIfPresent(String.self, forKey: .paneID)) ?? nil
            windowIndex = (try? container.decodeIfPresent(Int.self, forKey: .windowIndex)) ?? nil
            panePID = (try? container.decodeIfPresent(Int.self, forKey: .panePID)) ?? nil
            isDead = ((try? container.decodeIfPresent(Bool.self, forKey: .dead)) ?? nil) ?? false
            currentPath = (try? container.decodeIfPresent(String.self, forKey: .currentPath)) ?? nil
            currentCommand = (try? container.decodeIfPresent(String.self, forKey: .currentCommand)) ?? nil
        }
    }

    /// What a reader does with one session's reading (`sonda-lectura.json`, `efecto`).
    public enum Effect: String, Sendable, Equatable {
        /// An agent with an id: it becomes the window's active agent (`ia`).
        case agent = "ia"
        /// An agent without an id yet: the saved conversation is not touched (`sin_id`).
        case unidentified = "sin_id"
        /// A **live** pane without any agent: the window is back at a shell (`shell`). The only
        /// reading that turns a saved agent into history.
        case shell
        /// Ambiguous, a dead pane, a session that is not live, or anything unknown: nothing changes.
        case nothing = "nada"
    }

    /// One tmux session, already combined by the probe.
    public struct Session: Sendable, Equatable, Decodable {
        /// The tmux session name.
        public let name: String
        /// The live tmux session id (`$N`).
        public let sessionID: String?
        /// The live id of the pane that decided (`%N`).
        public let paneID: String?
        /// The shell pid of the pane that decided.
        public let panePID: Int?
        /// Whether the session exists now. The probe always says `true`; `false` only comes from a
        /// reader that synthesises a session it did not see, and reads like `panel_muerto`.
        public let isLive: Bool
        /// `nil` (agent with id), `sin_id`, `sin_ia`, `identidad_ambigua` or `panel_muerto`.
        public let reason: String?
        /// The single agent, or `nil`.
        public let agent: Agent?
        /// Every pane of the session, dead ones included.
        public let panes: [Pane]

        private enum CodingKeys: String, CodingKey {
            case name, live, reason, agent, panes
            case sessionID = "session_id"
            case paneID = "pane_id"
            case panePID = "pane_pid"
        }

        /// Creates a session entry, for tests.
        ///
        /// - Parameters:
        ///   - name: The tmux session name.
        ///   - sessionID: The live `$N`.
        ///   - paneID: The deciding pane's `%N`.
        ///   - panePID: The deciding pane's shell pid.
        ///   - isLive: Whether the session exists now.
        ///   - reason: The probe's reason.
        ///   - agent: The agent, if any.
        ///   - panes: The session's panes.
        public init(
            name: String, sessionID: String?, paneID: String?, panePID: Int? = nil, isLive: Bool = true,
            reason: String?, agent: Agent?, panes: [Pane] = []
        ) {
            self.name = name
            self.sessionID = sessionID
            self.paneID = paneID
            self.panePID = panePID
            self.isLive = isLive
            self.reason = reason
            self.agent = agent
            self.panes = panes
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            sessionID = (try? container.decodeIfPresent(String.self, forKey: .sessionID)) ?? nil
            paneID = (try? container.decodeIfPresent(String.self, forKey: .paneID)) ?? nil
            panePID = (try? container.decodeIfPresent(Int.self, forKey: .panePID)) ?? nil
            isLive = ((try? container.decodeIfPresent(Bool.self, forKey: .live)) ?? nil) ?? false
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            agent = try container.decodeIfPresent(Agent.self, forKey: .agent)
            panes = try container.decodeIfPresent([Pane].self, forKey: .panes) ?? []
        }

        /// Whether the pane that decided is dead: `panel_muerto`, a session that is not live, or
        /// its deciding pane listed as dead.
        public var isDeadPane: Bool {
            if reason == "panel_muerto" || !isLive { return true }
            guard let paneID else { return false }
            return panes.first(where: { $0.paneID == paneID })?.isDead ?? false
        }

        /// What a reader may do with this session (`contracts/agent-tree-v1/sonda-lectura.json`).
        ///
        /// Only `sin_ia` of a **live** pane leads to a shell: a dead pane kept by `remain-on-exit`
        /// does not say the agent was closed.
        public var effect: Effect {
            if isDeadPane { return .nothing }
            switch reason {
            case nil:
                guard let agent, agent.sessionID != nil else { return .nothing }
                return .agent
            case "sin_id"?:
                return agent == nil ? .nothing : .unidentified
            case "sin_ia"?:
                return .shell
            default:
                return .nothing
            }
        }
    }

    /// Always 1; any other version fails to decode.
    public let version: Int
    /// When the probe read the server (ISO 8601, UTC).
    public let checkedAt: String?
    /// The tmux socket that was probed (`default` is the default server).
    public let socket: String?
    /// The host name of the machine that ran the probe.
    public let hostName: String?
    /// The uid the probe ran as (`host.uid`); `0` is root.
    public let uid: Int?
    /// The platform of the machine that ran the probe (`linux`, `darwin`).
    public let platform: String?
    /// Whether the tmux server of that socket answered with panes.
    public let server: Bool
    /// `tmux_no_disponible`, `tmux_fallo`, `sonda_fallo: <Tipo>` or `nil`. With an error nothing
    /// stored is touched and nothing is taken as gone.
    public let error: String?
    /// Whether the probe left processes, panes or sessions out; then a missing session says nothing.
    public let truncated: Bool
    /// Every session the probe read.
    public let sessions: [Session]

    /// Errors a report can fail to decode with.
    public enum ReportError: Error, Equatable {
        /// The report is not version 1.
        case unsupportedVersion(Int)
    }

    /// Creates a report, for tests.
    ///
    /// - Parameters:
    ///   - version: Always 1.
    ///   - socket: The probed socket.
    ///   - uid: The uid the probe ran as.
    ///   - server: Whether the server answered.
    ///   - error: The error code, if any.
    ///   - truncated: Whether the output was cut.
    ///   - sessions: The sessions read.
    public init(
        version: Int = 1, socket: String?, uid: Int?, server: Bool = true, error: String? = nil,
        truncated: Bool = false, sessions: [Session]
    ) {
        self.version = version
        self.checkedAt = nil
        self.socket = socket
        self.hostName = nil
        self.uid = uid
        self.platform = nil
        self.server = server
        self.error = error
        self.truncated = truncated
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case version, socket, host, server, error, truncated, sessions
        case checkedAt = "checked_at"
    }

    private enum HostKeys: String, CodingKey {
        case hostname, uid, platform
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else { throw ReportError.unsupportedVersion(version) }
        checkedAt = (try? container.decodeIfPresent(String.self, forKey: .checkedAt)) ?? nil
        socket = (try? container.decodeIfPresent(String.self, forKey: .socket)) ?? nil
        if (try? container.decodeNil(forKey: .host)) == false,
           let host = try? container.nestedContainer(keyedBy: HostKeys.self, forKey: .host) {
            hostName = (try? host.decodeIfPresent(String.self, forKey: .hostname)) ?? nil
            uid = (try? host.decodeIfPresent(Int.self, forKey: .uid)) ?? nil
            platform = (try? host.decodeIfPresent(String.self, forKey: .platform)) ?? nil
        } else {
            hostName = nil
            uid = nil
            platform = nil
        }
        server = ((try? container.decodeIfPresent(Bool.self, forKey: .server)) ?? nil) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error)
        truncated = ((try? container.decodeIfPresent(Bool.self, forKey: .truncated)) ?? nil) ?? false
        if error == nil {
            sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        } else {
            sessions = []
        }
    }

    /// The error code without the exception type (`sonda_fallo: KeyError` → `sonda_fallo`).
    public var errorCode: String? {
        guard let error else { return nil }
        let code = error.split(separator: ":", maxSplits: 1).first.map(String.init) ?? error
        return code.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a session missing from ``sessions`` can be taken as gone (`ausente_es_desaparecida`).
    ///
    /// Only without an error and without truncation; with `server: false` every session is missing.
    public var missingMeansGone: Bool {
        error == nil && !truncated
    }

    /// The reading of one tmux session.
    ///
    /// - Parameter name: The tmux session name.
    /// - Returns: The session, or `nil` when the report carries an error or does not list it.
    public func session(named name: String) -> Session? {
        guard error == nil else { return nil }
        return sessions.first { $0.name == name }
    }

    /// The largest output a reader accepts: 262 144 bytes of JSON plus the final newline.
    public static let maximumOutputBytes = 256 * 1_024 + 1

    /// Decodes the probe's standard output, refusing anything larger than ``maximumOutputBytes``.
    ///
    /// - Parameter output: The bytes the probe printed.
    /// - Returns: The report, or `nil` when it is too large, not JSON or not version 1.
    public static func decode(output: Data) -> AgentProbeReport? {
        guard output.count <= maximumOutputBytes else { return nil }
        return try? JSONDecoder().decode(AgentProbeReport.self, from: output)
    }
}
