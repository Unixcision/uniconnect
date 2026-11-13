import Foundation

/// The terminals «Dictado» pastes into; the app passes ``UniConnectDictationTerminalBridge``.
@MainActor
protocol UniConnectDictationTerminals: AnyObject {
    /// The terminal focused in the frontmost UniConnect window, if there is one.
    func focusedTarget() -> UniConnectDictationTarget?

    /// Pastes `text` into `target` the way a paste arrives (bracketed when the program asked
    /// for it), without pressing Enter.
    ///
    /// - Returns: `false` when that window is gone or its terminal could not take the text.
    func paste(_ text: String, into target: UniConnectDictationTarget) -> Bool

    /// Presses Enter in `target`, as a keypress of its own after a short gap, never as the tail of
    /// a paste (the phone's rule), so Claude or Codex send what is in their box.
    ///
    /// - Returns: `false` when that window is gone or its terminal could not take the key.
    func submit(in target: UniConnectDictationTarget) async -> Bool
}
