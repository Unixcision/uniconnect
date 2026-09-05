import Foundation

/// A terminal or coding-agent destination that can be launched inside a local UniConnect window.
enum UniConnectLocalWindowLaunchTarget: Hashable, Identifiable, Sendable {
    case terminal
    case claude
    case codex
    case agy
    case grok
    case command(name: String, executable: String)
    case custom(id: String, name: String, executable: String, iconAssetName: String?)

    var id: String {
        switch self {
        case .terminal: return "terminal"
        case .claude: return "claude"
        case .codex: return "codex"
        case .agy: return "agy"
        case .grok: return "grok"
        case .command(let name, let executable): return "command:\(name)\u{0}\(executable)"
        case .custom(let id, _, _, _): return "custom:\(id)"
        }
    }

    var displayName: String {
        switch self {
        case .terminal:
            return String(localized: "uniconnect.localWindow.target.terminal", defaultValue: "Terminal")
        case .claude:
            return String(localized: "sessionIndex.agent.claude", defaultValue: "Claude Code")
        case .codex:
            return String(localized: "sessionIndex.agent.codex", defaultValue: "Codex")
        case .agy:
            return String(localized: "uniconnect.localWindow.target.agy", defaultValue: "Agy")
        case .grok:
            return String(localized: "sessionIndex.agent.grok", defaultValue: "Grok")
        case .command(let name, _):
            return name
        case .custom(_, let name, _, _):
            return name
        }
    }

    var localizedSummary: String {
        switch self {
        case .terminal:
            return String(
                localized: "uniconnect.localWindow.target.terminal.summary",
                defaultValue: "A normal login shell, ready for any command."
            )
        case .claude:
            return String(
                localized: "uniconnect.localWindow.target.claude.summary",
                defaultValue: "Claude with trusted-folder permissions enabled."
            )
        case .codex:
            return String(
                localized: "uniconnect.localWindow.target.codex.summary",
                defaultValue: "Codex in YOLO mode for this trusted folder."
            )
        case .agy:
            return String(
                localized: "uniconnect.localWindow.target.agy.summary",
                defaultValue: "Agy with trusted-folder permissions enabled."
            )
        case .grok:
            return String(
                localized: "uniconnect.localWindow.target.grok.summary",
                defaultValue: "Grok CLI in this window’s folder."
            )
        case .command:
            return String(
                localized: "uniconnect.localWindow.target.command.summary",
                defaultValue: "One-off shell command; UniConnect cannot resume it."
            )
        case .custom:
            return String(
                localized: "uniconnect.localWindow.target.custom.summary",
                defaultValue: "A configured CLI agent in this window’s folder."
            )
        }
    }

    var systemImageName: String {
        switch self {
        case .terminal: return "terminal.fill"
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .agy: return "a.circle.fill"
        case .grok: return "bolt.horizontal.circle.fill"
        case .command: return "terminal.badge.ellipsis"
        case .custom: return "person.crop.circle.badge.gearshape"
        }
    }

    var iconAssetName: String? {
        switch self {
        case .terminal: return nil
        case .claude: return "AgentIcons/Claude"
        case .codex: return "AgentIcons/Codex"
        case .agy: return "AgentIcons/Antigravity"
        case .grok: return "AgentIcons/Grok"
        case .command: return nil
        case .custom(_, _, _, let iconAssetName): return iconAssetName
        }
    }

    var restorableAgentKind: RestorableAgentKind? {
        switch self {
        case .terminal: return nil
        case .claude: return .claude
        case .codex: return .codex
        case .agy: return .antigravity
        case .grok: return .grok
        case .command: return nil
        case .custom(let id, _, _, _): return .custom(id)
        }
    }

    /// Builds a start command in a validated per-window cwd without replacing the shell.
    func startupCommand(
        boxRoot: String,
        workingDirectory: String? = nil
    ) -> String? {
        let argv: [String]
        switch self {
        case .terminal:
            return nil
        case .claude:
            argv = ["claude", "--dangerously-skip-permissions"]
        case .codex:
            argv = ["codex", "--yolo"]
        case .agy:
            argv = ["agy", "--dangerously-skip-permissions"]
        case .grok:
            argv = ["grok"]
        case .command(_, let executable):
            let normalizedExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedExecutable.isEmpty,
                  !normalizedExecutable.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                return nil
            }
            argv = [normalizedExecutable]
        case .custom(_, _, let executable, _):
            let normalizedExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedExecutable.isEmpty,
                  !normalizedExecutable.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                return nil
            }
            argv = [normalizedExecutable]
        }
        let command = argv
            .map(TerminalStartupShellQuoting.singleQuoted)
            .joined(separator: " ")
        return UniConnectLocalBoxRootPolicy.commandRequiringWorkingDirectory(
            command,
            workingDirectory: workingDirectory ?? boxRoot,
            boxRoot: boxRoot
        )
    }

    static var builtInAgents: [UniConnectLocalWindowLaunchTarget] {
        [.claude, .codex, .agy, .grok]
    }

    static func customTargets(
        from registry: CmuxVaultAgentRegistry
    ) -> [UniConnectLocalWindowLaunchTarget] {
        let representedIDs: Set<String> = ["antigravity", "grok"]
        return registry.registrations.compactMap { registration in
            guard !representedIDs.contains(registration.id),
                  let target = makeCustom(
                      id: registration.id,
                      name: registration.name,
                      executable: registration.defaultExecutable,
                      iconAssetName: registration.iconAssetName
                  ) else {
                return nil
            }
            return target
        }
    }

    /// Builds a ``custom(id:name:executable:iconAssetName:)`` target from raw
    /// registry values, or `nil` when they do not describe a usable agent.
    ///
    /// Named `makeCustom` rather than `custom` on purpose. An overload named for
    /// its own case is a trap: inside the factory, `return .custom(…)` resolves to
    /// the factory itself — an exact match, where the case would need promoting to
    /// `Optional` — so the call recursed until the stack guard tripped and the app
    /// died with SIGSEGV whenever a registry held a custom agent.
    ///
    /// - Parameters:
    ///   - id: Registry identifier; must satisfy ``CmuxVaultAgentRegistration/isValidID(_:)``.
    ///   - name: Display name; must not be blank after trimming.
    ///   - executable: Command to launch; must be non-blank and free of control characters.
    ///   - iconAssetName: Optional asset name; blank values are treated as absent.
    /// - Returns: The target, or `nil` when any value is unusable.
    static func makeCustom(
        id: String,
        name: String,
        executable: String,
        iconAssetName: String? = nil
    ) -> UniConnectLocalWindowLaunchTarget? {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CmuxVaultAgentRegistration.isValidID(normalizedID),
              !normalizedName.isEmpty,
              !normalizedExecutable.isEmpty,
              !normalizedExecutable.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        let normalizedIcon = iconAssetName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .custom(
            id: normalizedID,
            name: normalizedName,
            executable: normalizedExecutable,
            iconAssetName: normalizedIcon?.isEmpty == false ? normalizedIcon : nil
        )
    }

    /// Creates a one-off executable launch that intentionally has no resume descriptor.
    static func oneOffCommand(
        name: String,
        executable: String
    ) -> UniConnectLocalWindowLaunchTarget? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              !normalizedExecutable.isEmpty,
              !normalizedName.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !normalizedExecutable.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return .command(name: normalizedName, executable: normalizedExecutable)
    }
}
