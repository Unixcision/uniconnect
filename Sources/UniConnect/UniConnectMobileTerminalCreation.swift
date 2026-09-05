import Foundation

/// An explicit, secret-free request to create a desktop window from a remote client.
struct UniConnectMobileTerminalCreation: Equatable, Sendable {
    let name: String
    let tmuxSession: String?
    let directory: String?
    let agentID: String

    init?(name: String?, tmuxSession: String?, directory: String?, agentID: String?, isSSH: Bool) {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.utf8.count <= UniConnectLocalWindowRecord.maximumVisibleNameUTF8Bytes,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directory {
            guard directory.hasPrefix("/"), directory.utf8.count <= 4_096,
                  !directory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        }
        let agentID = agentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "terminal"
        guard !agentID.isEmpty, agentID.utf8.count <= 128,
              !agentID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let tmuxSession = tmuxSession?.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSSH {
            guard let tmuxSession, !tmuxSession.isEmpty,
                  UniConnectSSH.sanitizedTmuxName(tmuxSession) == tmuxSession,
                  agentID == "terminal" else { return nil }
        } else if tmuxSession != nil {
            // Local names are assigned from the stable window UUID, not from a remote session.
            return nil
        }
        self.name = name
        self.tmuxSession = tmuxSession
        self.directory = directory
        self.agentID = agentID
    }

    func localRequest(
        boxRoot: String,
        availableTargets: [UniConnectLocalWindowLaunchTarget]
    ) -> UniConnectNewLocalWindowRequest? {
        guard tmuxSession == nil,
              let target = ([.terminal] + availableTargets).first(where: { $0.id == agentID }) else { return nil }
        return UniConnectNewLocalWindowRequest(
            visibleName: name, boxRoot: boxRoot, workingDirectory: directory, launchTarget: target
        )
    }
}
