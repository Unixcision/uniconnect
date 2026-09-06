import Foundation

/// Owns only the terminal client created for one mobile attachment.
protocol MobilePTYRunning: Actor {
    func start(command: String, columns: Int, rows: Int) throws -> AsyncStream<MobilePTYOutput>
    func write(_ data: Data) throws
    func resize(columns: Int, rows: Int) throws
    func close()
}
