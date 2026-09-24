import Foundation

/// Everything the «Detalles» of one window shows, in the shape of `window_details.v1`.
///
/// The desktop modal and the phone read the same value: the modal renders it, and
/// ``mobilePayload`` turns it into exactly the JSON of `contracts/window-details-v1`. Every key is
/// always present, `null` when it does not apply. It never carries the connection command, a
/// password or the vault credential id.
struct UniConnectWindowDetailsSnapshot: Equatable, Sendable {
    enum Kind: String, Sendable {
        case local
        case ssh
    }

    /// The effective SSH endpoint.
    struct Host: Equatable, Sendable {
        let user: String
        let hostname: String
        let port: Int
    }

    /// The window's tmux identity: socket and session are durable; `$N`/`%N` exist only live.
    struct Tmux: Equatable, Sendable {
        let socket: String
        let session: String
        var sessionID: String?
        var paneID: String?
        var live: Bool
    }

    /// Whether the agent was confirmed now, is only what was saved, or will be resumed on open.
    enum AgentState: String, Sendable {
        case active = "activo"
        case saved = "guardado"
        case interrupted = "interrumpido"
    }

    /// The derived resume command; never persisted.
    struct Resume: Equatable, Sendable {
        let argv: [String]
        let environment: [String: String]
        let command: String
        let noPromptVerified: Bool
    }

    struct Agent: Equatable, Sendable {
        /// The wire id: `claude`, `codex`, `agy`, `grok` or another catalogue id.
        let provider: String
        let displayName: String
        let sessionID: String?
        let workingDirectory: String?
        let asRoot: Bool
        /// `ficha`, `rollout`, `argv`, `hook`, `manifiesto` or `registro`; `nil` without an id.
        let source: String?
        let state: AgentState
        let observedAt: Date?
        let resume: Resume?
    }

    let workspaceID: UUID
    let terminalID: UUID
    var checkedAt: Date
    let workspaceName: String
    let kind: Kind
    let host: Host?
    let hostLabel: String?
    let windowName: String
    var tmux: Tmux?
    var agent: Agent?
    /// `sin_ia`, `identidad_ambigua`, `sin_id`, `host_inaccesible`, `sin_tmux` or `nil`.
    var reason: String?

    /// Creates a snapshot from its parts.
    init(
        workspaceID: UUID,
        terminalID: UUID,
        checkedAt: Date,
        workspaceName: String,
        kind: Kind,
        host: Host?,
        hostLabel: String?,
        windowName: String,
        tmux: Tmux?,
        agent: Agent?,
        reason: String?
    ) {
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.checkedAt = checkedAt
        self.workspaceName = workspaceName
        self.kind = kind
        self.host = host
        self.hostLabel = hostLabel
        self.windowName = windowName
        self.tmux = tmux
        self.agent = agent
        self.reason = reason
    }

    /// Reads a `mobile.terminal.details` response back, the inverse of ``mobilePayload``.
    ///
    /// Used to check the contract fixtures against the same rendering the modal uses; `nil` when a
    /// required key is missing or has the wrong type.
    init?(mobilePayload payload: [String: Any]) {
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime]
        guard payload["version"] as? Int == 1,
              let workspaceID = (payload["workspace_id"] as? String).flatMap(UUID.init(uuidString:)),
              let terminalID = (payload["terminal_id"] as? String).flatMap(UUID.init(uuidString:)),
              let checkedAt = (payload["checked_at"] as? String).flatMap({ dates.date(from: $0) }),
              let workspace = payload["workspace"] as? [String: Any],
              let workspaceName = workspace["name"] as? String,
              let kind = (workspace["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let window = payload["window"] as? [String: Any],
              let windowName = window["name"] as? String else { return nil }
        var host: Host?
        if let value = workspace["host"] as? [String: Any] {
            guard let user = value["user"] as? String, let hostname = value["hostname"] as? String,
                  let port = value["port"] as? Int else { return nil }
            host = Host(user: user, hostname: hostname, port: port)
        }
        var tmux: Tmux?
        if let value = payload["tmux"] as? [String: Any] {
            guard let socket = value["socket"] as? String, let session = value["session"] as? String,
                  let live = value["live"] as? Bool else { return nil }
            tmux = Tmux(
                socket: socket, session: session, sessionID: value["session_id"] as? String,
                paneID: value["pane_id"] as? String, live: live
            )
        }
        var agent: Agent?
        if let value = payload["agent"] as? [String: Any] {
            guard let provider = value["provider"] as? String,
                  let displayName = value["display_name"] as? String,
                  let asRoot = value["as_root"] as? Bool,
                  let state = (value["state"] as? String).flatMap(AgentState.init(rawValue:)) else { return nil }
            var resume: Resume?
            if let entry = value["resume"] as? [String: Any] {
                guard let argv = entry["argv"] as? [String],
                      let environment = entry["environment"] as? [String: String],
                      let command = entry["command"] as? String,
                      let verified = entry["no_prompt_verified"] as? Bool else { return nil }
                resume = Resume(argv: argv, environment: environment, command: command, noPromptVerified: verified)
            }
            agent = Agent(
                provider: provider,
                displayName: displayName,
                sessionID: value["session_id"] as? String,
                workingDirectory: value["cwd"] as? String,
                asRoot: asRoot,
                source: value["source"] as? String,
                state: state,
                observedAt: (value["observed_at"] as? String).flatMap { dates.date(from: $0) },
                resume: resume
            )
        }
        self.init(
            workspaceID: workspaceID,
            terminalID: terminalID,
            checkedAt: checkedAt,
            workspaceName: workspaceName,
            kind: kind,
            host: host,
            hostLabel: workspace["host_label"] as? String,
            windowName: windowName,
            tmux: tmux,
            agent: agent,
            reason: payload["reason"] as? String
        )
    }

    /// The `mobile.terminal.details` response, key for key as in `contracts/window-details-v1`.
    var mobilePayload: [String: Any] {
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime]
        dates.timeZone = TimeZone(identifier: "UTC")
        func value(_ optional: Any?) -> Any { optional ?? NSNull() }
        let hostValue: Any = host.map {
            ["user": $0.user, "hostname": $0.hostname, "port": $0.port] as [String: Any]
        } ?? NSNull()
        let tmuxValue: Any = tmux.map {
            [
                "socket": $0.socket,
                "session": $0.session,
                "session_id": value($0.sessionID),
                "pane_id": value($0.paneID),
                "live": $0.live,
            ] as [String: Any]
        } ?? NSNull()
        let agentValue: Any = agent.map { agent -> [String: Any] in
            let resumeValue: Any = agent.resume.map {
                [
                    "argv": $0.argv,
                    "environment": $0.environment,
                    "command": $0.command,
                    "no_prompt_verified": $0.noPromptVerified,
                ] as [String: Any]
            } ?? NSNull()
            return [
                "provider": agent.provider,
                "display_name": agent.displayName,
                "session_id": value(agent.sessionID),
                "cwd": value(agent.workingDirectory),
                "as_root": agent.asRoot,
                "source": value(agent.source),
                "state": agent.state.rawValue,
                "observed_at": value(agent.observedAt.map { dates.string(from: $0) }),
                "resume": resumeValue,
            ]
        } ?? NSNull()
        return [
            "version": 1,
            "workspace_id": workspaceID.uuidString.lowercased(),
            "terminal_id": terminalID.uuidString.lowercased(),
            "checked_at": dates.string(from: checkedAt),
            "workspace": [
                "name": workspaceName,
                "kind": kind.rawValue,
                "host": hostValue,
                "host_label": value(hostLabel),
            ] as [String: Any],
            "window": ["name": windowName],
            "tmux": tmuxValue,
            "agent": agentValue,
            "reason": value(reason),
        ]
    }
}
