import Foundation

/// A stable, non-sensitive failure code suitable for display and diagnostics.
public enum ClaudeBridgeFailureCode: String, Codable, Sendable, Equatable {
    /// An incoming frame was not valid bridge JSON.
    case malformedFrame

    /// An incoming frame did not authenticate for its registered route.
    case authentication

    /// The encrypted local token repository could not be read or written.
    case tokenStore

    /// The remote integration reported an unexpected setup failure.
    case remoteSetup
}
