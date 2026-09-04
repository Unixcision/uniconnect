import Foundation

/// Bounded output and exit status produced by a controlled child process.
struct UniConnectProcessResult: Sendable, Equatable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
    let outputWasTruncated: Bool
}
