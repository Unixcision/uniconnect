import Foundation
import UniConnectClaudeUpdate

/// Verifies a local target against process scope, wrapper metadata, UUID, cwd, and executable.
actor UniConnectClaudeLocalProcessInspector {
    enum InspectionError: Error, Sendable, Equatable {
        case invalidTarget
        case panelUnavailable
        case identityMismatch
    }

    typealias ProcessSnapshotProvider = @Sendable () -> CmuxTopProcessSnapshot

    private let stateReader: any UniConnectClaudeUpdateApplicationStateReading
    private let binaryUpdater: any ClaudeBinaryUpdating
    private let processSnapshotProvider: ProcessSnapshotProvider

    init(
        stateReader: any UniConnectClaudeUpdateApplicationStateReading,
        binaryUpdater: any ClaudeBinaryUpdating,
        processSnapshotProvider: @escaping ProcessSnapshotProvider = {
            CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        }
    ) {
        self.stateReader = stateReader
        self.binaryUpdater = binaryUpdater
        self.processSnapshotProvider = processSnapshotProvider
    }

    func inspect(_ target: ClaudeUpdateTarget) async throws -> ClaudeSessionInspection {
        guard target.host.kind == .local,
              target.host.id == UniConnectClaudeUpdateHostID.local,
              target.pane == nil,
              let binding = target.binding,
              let workspaceID = UUID(uuidString: target.boxID),
              let panelID = UniConnectClaudeUpdateTargetIdentity.panelID(from: target.id) else {
            throw InspectionError.invalidTarget
        }
        guard let panel = await stateReader.panelSnapshot(
            workspaceID: workspaceID,
            panelID: panelID
        ) else {
            throw InspectionError.panelUnavailable
        }

        let snapshot = processSnapshotProvider()
        let candidates = snapshot.cmuxScopedProcesses().compactMap { process -> Int32? in
            guard process.cmuxWorkspaceID == workspaceID,
                  process.cmuxSurfaceID == panelID,
                  process.isTerminalForegroundProcessGroup,
                  process.pid > 1,
                  process.pid <= Int(Int32.max),
                  let arguments = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(
                    for: process.pid
                  ),
                  Self.matches(
                    processID: process.pid,
                    arguments: arguments,
                    binding: binding
                  ) else {
                return nil
            }
            return Int32(process.pid)
        }
        guard candidates.count == 1, let processID = candidates.first else {
            throw InspectionError.identityMismatch
        }

        let version = try? await binaryUpdater.installedVersion(
            on: target.host,
            executablePath: binding.executablePath
        )
        return ClaudeSessionInspection(
            isClaudeProcess: true,
            isIdle: panel.lifecycle == AgentHibernationLifecycleState.idle.rawValue,
            processID: processID,
            sessionID: binding.sessionID,
            workingDirectory: binding.workingDirectory,
            executablePath: binding.executablePath,
            version: version
        )
    }

    private static func matches(
        processID: Int,
        arguments: CmuxTopProcessArguments,
        binding: ClaudeSessionBinding
    ) -> Bool {
        let environment = arguments.environment
        let customConfigDirectory = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard customConfigDirectory?.isEmpty != false,
              environment["CMUX_AGENT_LAUNCH_KIND"] == "claude",
              environment["CMUX_CLAUDE_PID"] == String(processID),
              standardized(environment["CMUX_AGENT_LAUNCH_EXECUTABLE"])
                == standardized(binding.executablePath),
              standardized(environment["CMUX_AGENT_LAUNCH_CWD"])
                == standardized(binding.workingDirectory),
              explicitSessionID(arguments.arguments) == binding.sessionID else {
            return false
        }
        return true
    }

    private static func explicitSessionID(_ arguments: [String]) -> UUID? {
        let options = ["--session-id", "--resume", "-r"]
        for (index, argument) in arguments.enumerated() {
            for option in options {
                if argument == option,
                   arguments.indices.contains(index + 1),
                   let id = UUID(uuidString: arguments[index + 1]) {
                    return id
                }
                let prefix = option + "="
                if argument.hasPrefix(prefix),
                   let id = UUID(uuidString: String(argument.dropFirst(prefix.count))) {
                    return id
                }
            }
        }
        return nil
    }

    private static func standardized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("/"),
              !value.contains("\0") else {
            return nil
        }
        return (value as NSString).standardizingPath
    }
}
