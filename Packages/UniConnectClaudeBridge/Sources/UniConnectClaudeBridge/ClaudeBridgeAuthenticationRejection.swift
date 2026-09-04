import Foundation

/// Internal rejection categories intentionally avoid reflecting untrusted input.
enum ClaudeBridgeAuthenticationRejection: Error, Equatable {
    case malformed
    case stale
    case duplicate
    case unauthenticated
    case unknownRoute
}
