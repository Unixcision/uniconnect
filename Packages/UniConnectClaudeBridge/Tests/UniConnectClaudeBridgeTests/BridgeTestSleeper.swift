import Foundation

actor BridgeTestSleeper {
    private var sleepContinuation: CheckedContinuation<Void, any Error>?
    private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sleepContinuation = continuation
            let arrivals = arrivalContinuations
            arrivalContinuations.removeAll()
            for arrival in arrivals { arrival.resume() }
        }
    }

    func waitUntilSleeping() async {
        if sleepContinuation != nil { return }
        await withCheckedContinuation { continuation in
            arrivalContinuations.append(continuation)
        }
    }

    func fire() {
        sleepContinuation?.resume()
        sleepContinuation = nil
    }
}
