import AppKit
import Foundation

/// «Dictado»: the Mac's floating dictation button, read by this Mac's Whisper.
extension UniConnectCoordinator {
    /// Receives the engine and the history folder from the executable composition root.
    ///
    /// - Parameters:
    ///   - transcriber: This Mac's Whisper with the Mac dictation limits.
    ///   - historyDirectory: Where the dictations are kept.
    ///   - lockStates: UniConnect's lock, current value first.
    func configureDictation(
        transcriber: any UniConnectDictationTranscribing,
        historyDirectory: URL,
        lockStates: AsyncStream<Bool>
    ) {
        let model = UniConnectDictationModel(
            recorder: UniConnectDictationAudioRecorder(),
            player: UniConnectDictationAudioPlayer(),
            transcriber: transcriber,
            history: UniConnectDictationHistoryStore(directory: historyDirectory),
            terminals: UniConnectDictationTerminalBridge(),
            copyToPasteboard: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            },
            defaults: .standard
        )
        dictationController = UniConnectDictationPanelController(
            model: model,
            defaults: .standard,
            lockStates: lockStates
        )
    }

    /// Shows the floating button once the app finished launching.
    func startDictation() {
        dictationController?.start()
    }

    /// UniConnect › Dictado por voz…: opens the box, bringing the button back if it was hidden.
    func showDictation() {
        dictationController?.openBox()
    }
}
