import Foundation

enum MobilePTYOutput: Sendable, Equatable {
    case bytes(Data)
    case exited(Int32)
    case failed(MobilePTYProcessError)
}
