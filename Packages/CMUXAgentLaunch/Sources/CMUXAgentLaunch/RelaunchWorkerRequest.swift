import Foundation

/// One call to the Linux relaunch worker, with the same keys `RelaunchAgents.request` sends.
///
/// The worker reads exactly these keys (`linux/uniconnect/relaunch_worker.py`): `action`,
/// `session` and `socket` (both `[A-Za-z0-9_-]{1,40}`), `provider`, `window_id`, `catalog` (the
/// providers of `agent-resume-v1.json`), `recovery_sha256`, and per action `verb`, `expected` (the
/// proof the plan saw, sent back verbatim), `operation_id`; on `start`, `identity_helper` and, for
/// Claude, `messages` (`contracts/relaunch-v1/mensajes.json` whole). With
/// ``RelaunchVerb/agentUpdate`` `inspect` and `start` carry `options` (`{}` = igual que estaba) and
/// `start` carries `updated_to`; `update` carries the installation's `launcher` (09-11-2026).
public struct RelaunchWorkerRequest: Sendable, Equatable {
    /// What the worker is asked to do.
    public enum Action: String, Sendable {
        /// Read the pane and prove its agent; touches nothing.
        case inspect
        /// Accept the operation, journal it on the destination and run it detached.
        case start
        /// Read that operation's journal.
        case status
        /// Run `claude update` once for one installation (`launcher`), outside any pane.
        case update
    }

    /// The largest decoded payload the worker accepts.
    public static let maximumPayloadBytes = 65_536
    /// How long this call may take, as on Linux: `update` 300 s; Claude's `inspect` and `start`
    /// 40 s (`claude auth status` runs inside); everything else 18 s.
    public var timeout: Duration {
        if action == .update { return .seconds(300) }
        if provider == "claude", action == .inspect || action == .start { return .seconds(40) }
        return .seconds(18)
    }

    /// What to do.
    public let action: Action
    /// The tmux session.
    public let session: String
    /// The tmux socket name (`default` for SSH boxes).
    public let socket: String
    /// The agent in the pane (`claude`, `codex`, `agy`).
    public let provider: String
    /// The window's stable id.
    public let windowID: String
    /// The catalogue's `providers` object, as JSON.
    public let catalogProviders: Data
    /// The verb, for `inspect` and `start`.
    public let verb: RelaunchVerb?
    /// The plan's proof, sent back verbatim (JSON object), for `start` and `status`.
    public let expected: Data?
    /// The operation, for `start` and `status`.
    public let operationID: UUID?
    /// `agent.update`'s model and effort.
    public let options: RelaunchUpdateOptions?
    /// `mensajes.json` as a JSON object, sent with Claude's `start`.
    public let messages: Data?
    /// The version `claude update` left installed, sent with `agent.update`'s `start`.
    public let updatedTo: String?
    /// The installation's absolute launcher, for `update`.
    public let launcher: String?

    /// Creates a request.
    ///
    /// - Parameters:
    ///   - action: What to do.
    ///   - session: The tmux session.
    ///   - socket: The tmux socket name.
    ///   - provider: The agent.
    ///   - windowID: The window's id.
    ///   - catalogProviders: The catalogue's `providers` object.
    ///   - verb: The verb (`inspect`, `start`).
    ///   - expected: The plan's proof (`start`, `status`).
    ///   - operationID: The operation (`start`, `status`).
    ///   - options: `agent.update`'s options.
    ///   - messages: `mensajes.json` (Claude's `start`).
    ///   - updatedTo: The version after `claude update` (`agent.update`'s `start`).
    ///   - launcher: The installation's launcher (`update`).
    public init(
        action: Action,
        session: String,
        socket: String,
        provider: String,
        windowID: String,
        catalogProviders: Data,
        verb: RelaunchVerb? = nil,
        expected: Data? = nil,
        operationID: UUID? = nil,
        options: RelaunchUpdateOptions? = nil,
        messages: Data? = nil,
        updatedTo: String? = nil,
        launcher: String? = nil
    ) {
        self.action = action
        self.session = session
        self.socket = socket
        self.provider = provider
        self.windowID = windowID
        self.catalogProviders = catalogProviders
        self.verb = verb
        self.expected = expected
        self.operationID = operationID
        self.options = options
        self.messages = messages
        self.updatedTo = updatedTo
        self.launcher = launcher
    }

    /// The `providers` object of the catalogue bundled with this package, as JSON.
    ///
    /// - Returns: `nil` when the resource cannot be found or read.
    public static func bundledCatalogProviders() -> Data? {
        guard let url = AgentResumeResourceLocator().resourceURL(),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = object["providers"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: providers)
    }

    /// Whether `name` is a session or socket name the worker accepts.
    ///
    /// - Parameter name: A tmux session or socket name.
    /// - Returns: `true` for `[A-Za-z0-9_-]{1,40}`.
    public static func isValidTmuxName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) != nil
    }

    /// The JSON object the worker decodes.
    ///
    /// - Parameter source: The packed worker, for `recovery_sha256` and `identity_helper`.
    /// - Returns: The request object.
    /// - Throws: When the catalogue or the proof is not a JSON object.
    public func object(source: RelaunchWorkerSource) throws -> [String: Any] {
        guard let catalog = try JSONSerialization.jsonObject(with: catalogProviders) as? [String: Any] else {
            throw RelaunchError.invalidScope
        }
        var request: [String: Any] = [
            "action": action.rawValue, "session": session, "socket": socket,
            "provider": provider, "window_id": windowID, "catalog": catalog,
        ]
        if let verb { request["verb"] = verb.rawValue }
        if let expected {
            guard let proof = try JSONSerialization.jsonObject(with: expected) as? [String: Any] else {
                throw RelaunchError.tokenInvalid
            }
            request["expected"] = proof
        }
        if let operationID { request["operation_id"] = operationID.uuidString.lowercased() }
        if verb == .agentUpdate, action == .inspect || action == .start {
            request["options"] = (options ?? .unchanged).json
        }
        if verb == .agentUpdate, action == .start { request["updated_to"] = updatedTo ?? NSNull() }
        if action == .update { request["launcher"] = launcher ?? NSNull() }
        request["recovery_sha256"] = source.recoverySHA256 ?? NSNull()
        if action == .start {
            request["identity_helper"] = source.identityHelper
            if provider == "claude", let messages,
               let texts = try JSONSerialization.jsonObject(with: messages) as? [String: Any] {
                request["messages"] = texts
            }
        }
        return request
    }

    /// The command the box's SSH runs: `/bin/bash -lc 'python3 -c <bootstrap> <payload>'`.
    ///
    /// The same shape as Linux (`Transport.run` around `shlex.join(["python3", "-c", …])`), so a
    /// login shell's `PATH` finds `tmux` and the agents on the destination.
    ///
    /// - Parameter source: The packed worker.
    /// - Returns: The remote command line.
    /// - Throws: When the request cannot be encoded or is larger than the worker accepts.
    public func remoteCommand(source: RelaunchWorkerSource) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: object(source: source))
        guard payload.count <= Self.maximumPayloadBytes else { throw RelaunchError.invalidScope }
        let inner = RelaunchShellWords.join(["python3", "-c", source.bootstrap, payload.base64EncodedString()])
        return RelaunchShellWords.join(["/bin/bash", "-lc", inner])
    }
}
