import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

@Suite("Bounded mobile transport FIFO", .timeLimit(.minutes(1)))
struct MobileHostOutboundQueueTests {
    @Test func eventResponseAndNextEventShareOneFIFO() async throws {
        let queue = MobileHostOutboundQueue()
        var frames = queue.frames.makeAsyncIterator()
        #expect(queue.enqueue(Data([1]), topic: "terminal.render_grid") == .queued)
        let response = Task { await queue.send(Data([2])) }
        let first = try #require(await frames.next())
        let second = try #require(await frames.next())
        #expect(queue.enqueue(Data([3]), topic: "terminal.render_grid") == .queued)
        let third = try #require(await frames.next())
        #expect([first.data, second.data, third.data] == [Data([1]), Data([2]), Data([3])])
        #expect(first.topic == "terminal.render_grid")
        #expect(second.topic == nil)
        queue.complete(first, succeeded: true)
        queue.complete(second, succeeded: true)
        queue.complete(third, succeeded: true)
        #expect(await response.value)
        queue.close()
        #expect(await frames.next() == nil)
    }

    @Test func inFlightBytesRemainChargedUntilNetworkCompletion() async throws {
        let queue = MobileHostOutboundQueue(maximumFrames: 4, maximumBytes: 4)
        var frames = queue.frames.makeAsyncIterator()
        #expect(queue.enqueue(Data([1, 2, 3])) == .queued)
        let inFlight = try #require(await frames.next())
        #expect(queue.enqueue(Data([4, 5])) == .overflow)
        #expect(queue.isClosed)
        queue.complete(inFlight, succeeded: false)
        #expect(await frames.next() == nil)
    }

    @Test func networkCompletionReleasesByteAllowance() async throws {
        let queue = MobileHostOutboundQueue(maximumFrames: 2, maximumBytes: 4)
        var frames = queue.frames.makeAsyncIterator()
        #expect(queue.enqueue(Data([1, 2, 3, 4])) == .queued)
        let first = try #require(await frames.next())
        queue.complete(first, succeeded: true)
        #expect(queue.enqueue(Data([5, 6, 7, 8])) == .queued)
        let second = try #require(await frames.next())
        queue.complete(second, succeeded: true)
        queue.close()
        #expect(await frames.next() == nil)
    }

    @Test func inFlightFrameCountsAgainstTheFrameCap() async throws {
        let queue = MobileHostOutboundQueue(maximumFrames: 1, maximumBytes: 100)
        var frames = queue.frames.makeAsyncIterator()
        #expect(queue.enqueue(Data([1])) == .queued)
        let first = try #require(await frames.next())
        #expect(queue.enqueue(Data([2])) == .overflow)
        queue.complete(first, succeeded: false)
        #expect(await frames.next() == nil)
    }

    @Test func oversizeSingleFrameClosesInsteadOfDroppingAndContinuing() async {
        let queue = MobileHostOutboundQueue(maximumFrames: 64, maximumBytes: 4)
        #expect(queue.enqueue(Data(repeating: 1, count: 5)) == .overflow)
        #expect(queue.enqueue(Data([2])) == .closed)
        #expect(!(await queue.send(Data([3]))))
        var frames = queue.frames.makeAsyncIterator()
        #expect(await frames.next() == nil)
    }

    @Test func closureLetsTheConsumerReleaseAwaitingReceipts() async throws {
        let queue = MobileHostOutboundQueue()
        var frames = queue.frames.makeAsyncIterator()
        let response = Task { await queue.send(Data([1])) }
        let inFlight = try #require(await frames.next())
        #expect(queue.close())
        #expect(!queue.close())
        queue.complete(inFlight, succeeded: false)
        #expect(!(await response.value))
        #expect(await frames.next() == nil)
    }

    @Test func onlyOneConsumerCanBeStarted() {
        let queue = MobileHostOutboundQueue()
        #expect(queue.claimConsumer())
        for _ in 0..<100 { #expect(!queue.claimConsumer()) }
        queue.close()
    }

    @Test func concurrentProducersCannotOverReserveOrContinueAfterOverflow() async {
        let queue = MobileHostOutboundQueue(maximumFrames: 10, maximumBytes: 100)
        let results = await withTaskGroup(of: MobileHostOutboundQueue.EnqueueResult.self) { group in
            for _ in 0..<50 { group.addTask { queue.enqueue(Data([1])) } }
            var results: [MobileHostOutboundQueue.EnqueueResult] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(results.filter { $0 == .queued }.count == 10)
        #expect(results.filter { $0 == .overflow }.count == 1)
        #expect(results.filter { $0 == .closed }.count == 39)
        var received = 0
        for await frame in queue.frames {
            received += 1
            queue.complete(frame, succeeded: false)
        }
        #expect(received == 10)
    }
}
