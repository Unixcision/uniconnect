import Foundation

/// The validated, immutable request produced by the local new-window chooser.
struct UniConnectNewLocalWindowRequest: Equatable, Sendable {
    let visibleName: String
    let boxRoot: String
    /// An explicit per-window folder; `nil` follows the workspace default at creation time.
    let workingDirectory: String?
    let launchTarget: UniConnectLocalWindowLaunchTarget
    /// The user the agent runs as (`run-as.v1`); `nil` keeps the connected one.
    var runAs: UniConnectRunAs?
    /// Whether the agent starts with `IS_SANDBOX=1`.
    var isSandbox = false

    /// `IS_SANDBOX=1` as it will be applied: forced for Claude as root.
    var effectiveSandbox: Bool {
        UniConnectWindowLaunch.effectiveSandbox(requested: isSandbox, agent: launchTarget.id, runAs: runAs)
    }

    /// Whether the window opens at a shell and is switched to another user, or given
    /// `IS_SANDBOX`, before its agent is launched by hand.
    var switchesUser: Bool {
        (runAs?.mode ?? .current) != .current || (effectiveSandbox && launchTarget != .terminal)
    }

    /// What the window records about its agent's start.
    func launch(sessionID: String?) -> UniConnectWindowLaunch {
        UniConnectWindowLaunch(agent: launchTarget.id, isSandbox: effectiveSandbox, sessionID: sessionID)
    }

    init?(
        visibleName: String?,
        boxRoot: String,
        workingDirectory: String? = nil,
        launchTarget: UniConnectLocalWindowLaunchTarget
    ) {
        guard let normalizedRoot = UniConnectLocalWindowRecord.validatedBoxRoot(boxRoot) else {
            return nil
        }
        let normalizedWorkingDirectory: String?
        if let workingDirectory {
            guard let validated = UniConnectLocalWindowRecord.validatedWorkingDirectory(
                workingDirectory,
                within: normalizedRoot
            ) else { return nil }
            normalizedWorkingDirectory = validated
        } else {
            normalizedWorkingDirectory = nil
        }
        let normalizedName = visibleName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.map({
            $0.utf8.count <= UniConnectLocalWindowRecord.maximumVisibleNameUTF8Bytes
                && !$0.unicodeScalars.contains(where: { scalar in CharacterSet.controlCharacters.contains(scalar) })
        }) ?? true else { return nil }
        self.visibleName = normalizedName?.isEmpty == false
            ? normalizedName!
            : launchTarget.displayName
        self.boxRoot = normalizedRoot
        self.workingDirectory = normalizedWorkingDirectory
        self.launchTarget = launchTarget
    }

    /// Input queued after the login shell appears; `nil` means a plain terminal.
    var startupInput: String? {
        launchTarget.startupCommand(
            boxRoot: boxRoot,
            workingDirectory: workingDirectory
        ).map { $0 + "\n" }
    }
}
