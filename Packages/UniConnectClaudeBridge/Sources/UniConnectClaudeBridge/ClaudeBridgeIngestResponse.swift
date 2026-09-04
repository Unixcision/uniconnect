import Foundation

/// The non-sensitive result returned to a remote bridge sender.
public struct ClaudeBridgeIngestResponse: Codable, Sendable, Equatable {
    /// Whether the frame was accepted.
    public let accepted: Bool

    /// Whether an otherwise-valid event was already seen or coalesced.
    public let duplicate: Bool

    /// A stable failure code; never an exception string or credential.
    public let code: String?

    /// Creates a bounded response.
    ///
    /// - Parameters:
    ///   - accepted: Whether the frame was accepted.
    ///   - duplicate: Whether it was a duplicate.
    ///   - code: Optional stable failure code.
    public init(accepted: Bool, duplicate: Bool = false, code: String? = nil) {
        self.accepted = accepted
        self.duplicate = duplicate
        self.code = code
    }
}
