import Foundation

/// The shared `run-as.v1` wrapper, `contracts/run-as-v1/subir.sh`, as a pane command.
///
/// Linux and the Mac run the very same text: `sh -c "$(subir.sh)" uc-subir <sudo|su> <user>
/// <window-id> <orden>`. It is bundled from the contract unchanged, never rewritten here. The
/// password is not part of the command: sudo reads it through the wrapper's askpass from a 0600
/// file the host leaves just before the session starts, and su from the pane.
struct UniConnectRunAsWrapper: Equatable, Sendable {
    /// The wrapper's text.
    let script: String

    /// - Parameter script: The wrapper's text; tests pass the contract file's contents.
    init(script: String) {
        self.script = script
    }

    /// The bundled wrapper, or `nil` when the app was built without it.
    init?(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "subir", withExtension: "sh"),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        self.script = text
    }

    /// The window id the wrapper names its diary and secret after (`[A-Za-z0-9-]`).
    static func windowID(_ panelID: UUID) -> String {
        panelID.uuidString.lowercased()
    }

    /// The pane command for `runAs`, or `nil` when it does not switch user.
    func paneCommand(runAs: UniConnectRunAs, panelID: UUID, inner: String) -> String? {
        guard let user = runAs.targetUser else { return nil }
        let quote = TerminalStartupShellQuoting.singleQuoted
        return ["/bin/sh", "-c", quote(script), "uc-subir", runAs.method.rawValue,
                quote(user), Self.windowID(panelID), quote(inner)].joined(separator: " ")
    }
}
