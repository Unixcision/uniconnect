import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    func hermesAgentShellCommand(_ script: String) -> String {
        "sh -c \(shellQuote(script))"
    }

    func hermesAgentEvents(def: AgentHookDef) -> [HermesAgentHookConfig.Event] {
        var events = def.events.map { event in
            HermesAgentHookConfig.Event(
                name: event.agentEvent,
                command: hermesAgentShellCommand(hookCommand(for: def, event: event)),
                timeout: 5
            )
        }
        events.append(contentsOf: def.feedHookEvents.map { agentEvent in
            HermesAgentHookConfig.Event(
                name: agentEvent,
                command: hermesAgentShellCommand(feedHookCommand(for: def, agentEvent: agentEvent)),
                timeout: 120
            )
        })
        return events
    }

    func installHermesAgentHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let allowlistPath = "\(configDir)/shell-hooks-allowlist.json"
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")

        guard fm.fileExists(atPath: configDir) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.hermes.configMissing",
                    defaultValue: "%@ does not exist. Install %@ first."
                ),
                configDir,
                def.displayName
            ))
            return
        }

        let events = hermesAgentEvents(def: def)
        let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
        let newString = HermesAgentHookConfig.installing(events: events, in: oldString)

        if oldString != newString {
            if !skipConfirm {
                Self.printInstallPreview(
                    path: filePath,
                    oldContent: oldString,
                    newContent: newString,
                    fallbackContent: newString
                )
                print(String(localized: "cli.hooks.confirmProceed", defaultValue: "\nProceed? [y/N] "), terminator: "")
                guard readLine()?.lowercased().hasPrefix("y") == true else {
                    print(String(localized: "cli.hooks.aborted", defaultValue: "Aborted."))
                    return
                }
            }
            try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.agent.installed",
                    defaultValue: "%@ UniConnect hooks installed at %@"
                ),
                def.displayName,
                filePath
            ))
        } else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.agent.alreadyUpToDate",
                    defaultValue: "%@ UniConnect hooks already up to date at %@"
                ),
                def.displayName,
                filePath
            ))
        }

        let oldAllowlist = fm.contents(atPath: allowlistPath)
        let newAllowlist = try HermesAgentHookAllowlist.installing(events: events, in: oldAllowlist)
        if oldAllowlist != newAllowlist {
            try newAllowlist.write(to: URL(fileURLWithPath: allowlistPath), options: .atomic)
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.hermes.allowlistApproved",
                    defaultValue: "Approved %@ UniConnect shell hooks in %@"
                ),
                def.displayName,
                allowlistPath
            ))
        }
    }

    func uninstallHermesAgentHooks(_ def: AgentHookDef) throws {
        let fm = FileManager.default
        let configDir = def.resolvedConfigDir()
        let filePath = "\(configDir)/\(def.configFile)"
        let allowlistPath = "\(configDir)/shell-hooks-allowlist.json"
        let events = hermesAgentEvents(def: def)

        if fm.fileExists(atPath: filePath) {
            let oldString = try readAgentHookConfig(filePath: filePath, displayName: def.displayName)
            let newString = HermesAgentHookConfig.uninstalling(from: oldString)
            if oldString != newString {
                try newString.write(toFile: filePath, atomically: true, encoding: .utf8)
                print(String.localizedStringWithFormat(
                    String(
                        localized: "cli.hooks.hermes.removed",
                        defaultValue: "Removed Hermes Agent UniConnect hooks from %@"
                    ),
                    filePath
                ))
            } else {
                print(String.localizedStringWithFormat(
                    String(
                        localized: "cli.hooks.agent.removedZero",
                        defaultValue: "Removed 0 UniConnect hook(s) from %@"
                    ),
                    filePath
                ))
            }
        } else {
            print(String.localizedStringWithFormat(
                String(localized: "cli.hooks.agent.noneFound", defaultValue: "No %@ found at %@"),
                def.configFile,
                filePath
            ))
        }

        guard fm.fileExists(atPath: allowlistPath) else { return }
        let oldAllowlist = fm.contents(atPath: allowlistPath)
        let newAllowlist = try HermesAgentHookAllowlist.uninstalling(events: events, from: oldAllowlist)
        if oldAllowlist != newAllowlist {
            try newAllowlist.write(to: URL(fileURLWithPath: allowlistPath), options: .atomic)
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.hermes.allowlistRemoved",
                    defaultValue: "Removed Hermes Agent UniConnect shell hook approvals from %@"
                ),
                allowlistPath
            ))
        }
    }
}
