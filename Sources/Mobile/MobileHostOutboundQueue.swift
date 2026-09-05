import Foundation
import os

/// Bounded synchronous ingress for the connection actor's single async writer.
/// AsyncStream owns the FIFO; no task or unbounded staging queue precedes it.
final class MobileHostOutboundQueue: Sendable {
    struct Frame: Sendable {
        let data: Data
        let topic: String?
        fileprivate let receipt: CheckedContinuation<Bool, Never>?
    }

    enum EnqueueResult: Equatable {
        case queued
        case closed
        case overflow
    }

    let frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation
    private let maximumFrames: Int
    private let maximumBytes: Int
    // Synchronous CAS carve-out: reserve a tiny count/byte budget before yield
    // from non-async render callbacks. Stream/connection actor own all contents.
    private let budget = OSAllocatedUnfairLock(initialState: Budget())

    init(maximumFrames: Int = 64, maximumBytes: Int = 8 * 1024 * 1024) {
        self.maximumFrames = maximumFrames
        self.maximumBytes = maximumBytes
        (frames, continuation) = AsyncStream<Frame>.makeStream(bufferingPolicy: .bufferingOldest(maximumFrames))
    }

    var isClosed: Bool { budget.withLock { $0.closed } }

    /// Claims the one consumer without scheduling a task for every event.
    func claimConsumer() -> Bool {
        budget.withLock { state in
            guard !state.consumerClaimed else { return false }
            state.consumerClaimed = true
            return true
        }
    }

    func enqueue(_ data: Data, topic: String? = nil) -> EnqueueResult {
        enqueue(Frame(data: data, topic: topic, receipt: nil))
    }

    /// Awaits the actual network completion (or closure), not just acceptance.
    func send(_ data: Data) async -> Bool {
        await withCheckedContinuation { receipt in
            let result = enqueue(Frame(data: data, topic: nil, receipt: receipt))
            if result != .queued { receipt.resume(returning: false) }
        }
    }

    private func enqueue(_ frame: Frame) -> EnqueueResult {
        let result = budget.withLock { state -> EnqueueResult in
            guard !state.closed else { return .closed }
            guard state.frames < maximumFrames, frame.data.count <= maximumBytes - state.bytes else {
                state.closed = true
                return .overflow
            }
            state.frames += 1
            state.bytes += frame.data.count
            // Keeping reservation + yield in one short section preserves the
            // producer's enqueue order without a Task/await scheduling hop.
            switch continuation.yield(frame) {
            case .enqueued: return .queued
            case .dropped:
                state.frames -= 1
                state.bytes -= frame.data.count
                state.closed = true
                return .overflow
            case .terminated:
                state.frames -= 1
                state.bytes -= frame.data.count
                state.closed = true
                return .closed
            @unknown default:
                state.frames -= 1
                state.bytes -= frame.data.count
                state.closed = true
                return .overflow
            }
        }
        if result != .queued { continuation.finish() }
        return result
    }

    /// The sole consumer completes each yielded frame exactly once. Until then
    /// its bytes remain charged, including while NWConnection.send is in flight.
    func complete(_ frame: Frame, succeeded: Bool) {
        budget.withLock { state in
            state.frames -= 1
            state.bytes -= frame.data.count
        }
        frame.receipt?.resume(returning: succeeded)
    }

    @discardableResult
    func close() -> Bool {
        let changed = budget.withLock { state in
            let changed = !state.closed
            state.closed = true
            return changed
        }
        // finish drains buffered frames: the consumer must release their byte
        // reservations and resume receipts as false rather than cancel its Task.
        continuation.finish()
        return changed
    }

    private struct Budget {
        var frames = 0
        var bytes = 0
        var closed = false
        var consumerClaimed = false
    }
}
