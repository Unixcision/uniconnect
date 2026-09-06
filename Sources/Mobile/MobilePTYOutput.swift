import Foundation

enum MobilePTYOutput: Sendable, Equatable {
    case bytes(Data)
    case geometry(MobileTmuxGeometry)
    case exited(Int32)
    case failed(MobilePTYProcessError)
}
