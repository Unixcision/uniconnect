import Foundation
@testable import UniConnectClaudeUpdate

/// Builds deterministic, credential-free targets for package behavior tests.
struct ClaudeUpdateTestFixture {
    let localHost = ClaudeUpdateHostIdentity(kind: .local, id: "local", displayName: "This Mac")
    let remoteHost = ClaudeUpdateHostIdentity(
        kind: .remote,
        id: "ssh:credential-a@endpoint-a",
        displayName: "Test Server"
    )
    let versionBefore = ClaudeVersion(major: 1, minor: 2, patch: 3)
    let versionAfter = ClaudeVersion(major: 1, minor: 2, patch: 4)

    func target(
        id: String,
        host: ClaudeUpdateHostIdentity? = nil,
        sessionID: UUID = UUID(),
        installationID: String = "native:/opt/claude",
        executablePath: String = "/opt/claude/bin/claude",
        paneID: String? = nil,
        boxID: String = "box-a"
    ) -> ClaudeUpdateTarget {
        let resolvedHost = host ?? localHost
        let pane = paneID.map {
            ClaudeTmuxPaneIdentity(
                sessionName: "work",
                windowIndex: 0,
                paneIndex: 1,
                paneID: $0
            )
        }
        return ClaudeUpdateTarget(
            id: ClaudeUpdateTargetID(rawValue: id),
            boxID: boxID,
            displayName: id,
            host: resolvedHost,
            binding: ClaudeSessionBinding(
                sessionID: sessionID,
                workingDirectory: "/work/\(id)",
                executablePath: executablePath,
                installationID: installationID
            ),
            pane: pane
        )
    }
}
