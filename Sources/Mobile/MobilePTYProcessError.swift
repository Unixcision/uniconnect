import Foundation

/// Transport errors contain neither command text nor terminal contents.
enum MobilePTYProcessError: Error, Sendable, Equatable {
    case invalidRequest
    case alreadyStarted
    case notRunning
    case inputOverflow
    case outputOverflow
    case system(Int32)
}
