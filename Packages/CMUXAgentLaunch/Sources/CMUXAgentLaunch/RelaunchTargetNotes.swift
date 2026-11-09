import Foundation

/// What a plan says about one target besides its identity: warnings, what will be kept and what
/// it will cost (`contracts/relaunch-v1/plan-update-response.json`).
///
/// Everything here is shown to a person **before** confirming. None of it excludes the target: a
/// warning is something applying will stop, not a reason to leave the window alone.
public struct RelaunchTargetNotes: Sendable, Equatable {
    /// `tareas_de_fondo` or `permisos` when applying will interrupt something; `nil` otherwise.
    public var warning: RelaunchCause?
    /// How many background monitors or shells will be saved, stopped and offered back.
    public var background: Int?
    /// Whether the composer holds a draft that will be written back, without return.
    public var draft: Bool?
    /// The conversation's size in tokens from its last `usage`, or `nil` when unknown.
    public var contextTokens: Int?
    /// Whether a message will be typed after reopening (it had monitors or was working).
    public var message: Bool?
    /// The Claude version the live process runs (``RelaunchVerb/agentUpdate`` only).
    public var version: String?
    /// The Claude version installed on its machine before updating (``RelaunchVerb/agentUpdate``).
    public var installed: String?
    /// Names of the launch options that will not come back (never their values).
    public var droppedOptions: [String]

    /// Creates the notes of one target.
    ///
    /// - Parameters:
    ///   - warning: What applying interrupts, if anything.
    ///   - background: Monitors and shells to save.
    ///   - draft: Whether there is a draft to keep.
    ///   - contextTokens: The conversation's size, if known.
    ///   - message: Whether a message will be typed after reopening.
    ///   - version: The running Claude version.
    ///   - installed: The installed Claude version.
    ///   - droppedOptions: Option names that will be left out.
    public init(
        warning: RelaunchCause? = nil,
        background: Int? = nil,
        draft: Bool? = nil,
        contextTokens: Int? = nil,
        message: Bool? = nil,
        version: String? = nil,
        installed: String? = nil,
        droppedOptions: [String] = []
    ) {
        self.warning = warning
        self.background = background
        self.draft = draft
        self.contextTokens = contextTokens
        self.message = message
        self.version = version
        self.installed = installed
        self.droppedOptions = droppedOptions
    }

    /// Whether applying will interrupt something (`active: true` on the wire).
    public var active: Bool { warning != nil }

    /// The tokens the post-reopen message will make the agent reread: its context when a message
    /// is sent, nothing otherwise. Reopening on its own costs nothing.
    public var estimatedTokens: Int {
        message == true ? (contextTokens ?? 0) : 0
    }

    /// The fields this adds to a plan target, with absent values left out.
    public var json: [String: Any] {
        var fields: [String: Any] = [:]
        if let warning {
            fields["active"] = true
            fields["warning"] = warning.rawValue
        }
        if let background { fields["background"] = background }
        if let draft { fields["draft"] = draft }
        if let message {
            fields["message"] = message
            fields["context_tokens"] = contextTokens.map { $0 as Any } ?? NSNull()
        } else if let contextTokens {
            fields["context_tokens"] = contextTokens
        }
        if let version { fields["version"] = version }
        if let installed { fields["installed"] = installed }
        if !droppedOptions.isEmpty { fields["dropped_options"] = droppedOptions }
        return fields
    }
}
