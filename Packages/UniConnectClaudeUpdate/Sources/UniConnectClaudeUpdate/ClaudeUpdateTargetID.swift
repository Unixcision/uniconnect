import Foundation

/// A stable, non-secret identifier for one visible UniConnect terminal target.
public struct ClaudeUpdateTargetID: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    /// The application-owned stable identifier.
    public let rawValue: String

    /// Creates a target identifier.
    ///
    /// - Parameter rawValue: A stable panel or surface identifier that contains no credential.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The raw identifier used for diagnostics and persistence.
    public var description: String { rawValue }
}
