import Foundation

/// «0:07», «12:40»: how long a recording is, for the timer and the history.
struct UniConnectDictationClock: Equatable, Sendable {
    let seconds: TimeInterval

    var text: String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
