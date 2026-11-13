import AVFoundation
import Foundation

/// Plays «Dictado»'s kept recordings with `AVAudioPlayer`, one at a time.
@MainActor
final class UniConnectDictationAudioPlayer: NSObject, UniConnectDictationPlaying {
    private var player: AVAudioPlayer?
    private var onFinish: (@MainActor () -> Void)?

    func play(_ url: URL, onFinish: @escaping @MainActor () -> Void) -> Bool {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.delegate = self
        guard player.play() else { return false }
        self.player = player
        self.onFinish = onFinish
        return true
    }

    func stop() {
        player?.stop()
        player = nil
        onFinish = nil
    }

    private func playerFinished(_ finished: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == finished else { return }
        let onFinish = self.onFinish
        self.player = nil
        self.onFinish = nil
        onFinish?()
    }
}

extension UniConnectDictationAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            self.playerFinished(finished)
        }
    }
}
