import Foundation

/// The minimal 0600 session record written beside a remote bridge route.
///
/// Updaters may use a fresh record to recover an exact Claude UUID and working
/// directory without reading transcripts or falling back silently to `--continue`.
public struct ClaudeBridgeRemoteSessionRecord: Codable, Sendable, Equatable {
    /// Whether `sessionID` is a Claude UUID or a non-resumable correlation hash.
    public enum SessionKind: String, Codable, Sendable {
        /// An exact Claude Code session UUID suitable for `--resume` after validation.
        case uuid

        /// A privacy-safe correlation hash that is not suitable for `--resume`.
        case correlation
    }

    /// The latest content-free Claude activity observed for this exact route and pane.
    public enum ActivityState: String, Codable, Sendable {
        /// Claude has started or received work that has not completed yet.
        case running

        /// Claude emitted `Stop` or the `idle_prompt` notification.
        case idle
    }

    /// File contract version.
    public let version: Int

    /// Stable route UUID encoded by the remote writer.
    public let routeID: UUID

    /// Exact Claude UUID or correlation hash.
    public let sessionID: String

    /// Classification of ``sessionID``.
    public let sessionKind: SessionKind

    /// Remote absolute working directory.
    public let cwd: String

    /// Concrete tmux pane that emitted the hook.
    public let tmuxPane: String

    /// Latest content-free Claude lifecycle state for this route and pane.
    public let activityState: ActivityState

    /// Optional SHA-256 correlation for rejecting an older prompt's late completion.
    public let promptCorrelation: String?

    /// Remote observation time in milliseconds since 1970.
    public let observedAtMilliseconds: Int64

    /// Legacy spelling retained for source compatibility with the version-1 reader.
    @available(*, deprecated, renamed: "observedAtMilliseconds")
    public var updatedAtMilliseconds: Int64 { observedAtMilliseconds }

    enum CodingKeys: String, CodingKey {
        case version
        case routeID = "route_id"
        case sessionID = "session_id"
        case sessionKind = "session_kind"
        case cwd
        case tmuxPane = "tmux_pane"
        case activityState = "activity_state"
        case promptCorrelation = "prompt_correlation"
        case observedAtMilliseconds = "observed_at_ms"
        case legacyUpdatedAtMilliseconds = "updated_at_ms"
    }

    /// Creates one bounded remote journal value.
    ///
    /// - Parameters:
    ///   - version: File contract version, currently `1`.
    ///   - routeID: Stable trusted route UUID.
    ///   - sessionID: Exact Claude UUID or bounded correlation hash.
    ///   - sessionKind: Classification of `sessionID`.
    ///   - cwd: Remote absolute working directory.
    ///   - tmuxPane: Concrete tmux pane identifier.
    ///   - activityState: Latest content-free Claude lifecycle state.
    ///   - observedAtMilliseconds: Remote observation time in milliseconds since 1970.
    ///   - promptCorrelation: Optional content-free prompt correlation hash.
    public init(
        version: Int,
        routeID: UUID,
        sessionID: String,
        sessionKind: SessionKind,
        cwd: String,
        tmuxPane: String,
        activityState: ActivityState,
        observedAtMilliseconds: Int64,
        promptCorrelation: String? = nil
    ) {
        self.version = version
        self.routeID = routeID
        self.sessionID = sessionID
        self.sessionKind = sessionKind
        self.cwd = cwd
        self.tmuxPane = tmuxPane
        self.activityState = activityState
        self.observedAtMilliseconds = observedAtMilliseconds
        self.promptCorrelation = promptCorrelation
    }

    /// Decodes the current journal and the earlier idle-only timestamp spelling.
    ///
    /// - Parameter decoder: Decoder containing a version-1 session journal.
    /// - Throws: A decoding error when required bounded metadata is absent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        routeID = try container.decode(UUID.self, forKey: .routeID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        sessionKind = try container.decode(SessionKind.self, forKey: .sessionKind)
        cwd = try container.decode(String.self, forKey: .cwd)
        tmuxPane = try container.decode(String.self, forKey: .tmuxPane)
        activityState = try container.decodeIfPresent(ActivityState.self, forKey: .activityState) ?? .idle
        promptCorrelation = try container.decodeIfPresent(String.self, forKey: .promptCorrelation)
        if let observed = try container.decodeIfPresent(Int64.self, forKey: .observedAtMilliseconds) {
            observedAtMilliseconds = observed
        } else {
            observedAtMilliseconds = try container.decode(Int64.self, forKey: .legacyUpdatedAtMilliseconds)
        }
    }

    /// Encodes only the current privacy-minimal journal spelling.
    ///
    /// - Parameter encoder: Destination encoder.
    /// - Throws: An encoding error from the destination encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(routeID, forKey: .routeID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(sessionKind, forKey: .sessionKind)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(tmuxPane, forKey: .tmuxPane)
        try container.encode(activityState, forKey: .activityState)
        try container.encodeIfPresent(promptCorrelation, forKey: .promptCorrelation)
        try container.encode(observedAtMilliseconds, forKey: .observedAtMilliseconds)
    }

    /// Returns the exact UUID only when the record explicitly classifies it as one.
    public var resumableSessionID: UUID? {
        guard sessionKind == .uuid else { return nil }
        return UUID(uuidString: sessionID)
    }

    /// Validates identity, metadata shape, and freshness before updater use.
    ///
    /// - Parameters:
    ///   - expectedRouteID: Trusted route UUID selected locally.
    ///   - now: Local comparison time.
    ///   - maximumAge: Maximum accepted record age in seconds.
    ///   - futureTolerance: Maximum accepted positive clock skew in seconds.
    /// - Returns: `true` only for a bounded record that matches the trusted route.
    public func isValid(
        expectedRouteID: UUID,
        now: Date,
        maximumAge: TimeInterval = 10 * 60,
        futureTolerance: TimeInterval = 30
    ) -> Bool {
        guard version == 1,
              routeID == expectedRouteID,
              cwd.hasPrefix("/"),
              cwd.utf8.count <= 4_096,
              !cwd.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              tmuxPane.range(of: "^%[0-9]{1,12}$", options: .regularExpression) != nil else {
            return false
        }
        if let promptCorrelation {
            guard promptCorrelation.count == 64,
                  promptCorrelation.unicodeScalars.allSatisfy({ scalar in
                      (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
                  }) else { return false }
        }
        switch sessionKind {
        case .uuid:
            guard UUID(uuidString: sessionID) != nil else { return false }
        case .correlation:
            guard sessionID.count == 64,
                  sessionID.unicodeScalars.allSatisfy({ scalar in
                      (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
                  }) else { return false }
        }
        let observedAt = Date(timeIntervalSince1970: TimeInterval(observedAtMilliseconds) / 1_000)
        let age = now.timeIntervalSince(observedAt)
        return age <= maximumAge && age >= -futureTolerance
    }
}
