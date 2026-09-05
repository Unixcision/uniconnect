import Foundation
import UniConnectClaudeUpdate

/// Coordinates event-driven local and remote session exit, shell return, and restoration.
actor UniConnectClaudeSessionController: ClaudeSessionControlling {
    private enum InspectionWaitResult: Sendable {
        case inspection(ClaudeSessionInspection)
        case streamEnded
        case timedOut
    }

    private enum ShellWaitResult: Sendable {
        case ready
        case streamEnded
        case timedOut
    }

    private let stateReader: any UniConnectClaudeUpdateApplicationStateReading
    private let terminalWriter: any UniConnectClaudeTerminalWriting
    private let localInspector: UniConnectClaudeLocalProcessInspector
    private let remoteController: any UniConnectClaudeRemoteSessionControlling
    private let processExitWaiter: any UniConnectProcessExitWaiting
    private let sessionRegistry: UniConnectClaudeSessionRegistry
    private let wrapperPathProvider: @Sendable () -> String?
    private let idleTimeout: Duration
    private let shellTimeout: Duration
    private let restoreTimeout: Duration

    init(
        stateReader: any UniConnectClaudeUpdateApplicationStateReading,
        terminalWriter: any UniConnectClaudeTerminalWriting,
        localInspector: UniConnectClaudeLocalProcessInspector,
        remoteController: any UniConnectClaudeRemoteSessionControlling,
        processExitWaiter: any UniConnectProcessExitWaiting,
        sessionRegistry: UniConnectClaudeSessionRegistry,
        wrapperPathProvider: @escaping @Sendable () -> String? = {
            Bundle.main.resourceURL?
                .appendingPathComponent("bin/uniconnect-claude-wrapper", isDirectory: false)
                .path
        },
        idleTimeout: Duration = .seconds(90),
        shellTimeout: Duration = .seconds(30),
        restoreTimeout: Duration = .seconds(45)
    ) {
        self.stateReader = stateReader
        self.terminalWriter = terminalWriter
        self.localInspector = localInspector
        self.remoteController = remoteController
        self.processExitWaiter = processExitWaiter
        self.sessionRegistry = sessionRegistry
        self.wrapperPathProvider = wrapperPathProvider
        self.idleTimeout = idleTimeout
        self.shellTimeout = shellTimeout
        self.restoreTimeout = restoreTimeout
    }

    func inspect(_ target: ClaudeUpdateTarget) async throws -> ClaudeSessionInspection {
        switch target.host.kind {
        case .local:
            return try await localInspector.inspect(target)
        case .remote:
            return try await remoteController.inspect(target)
        }
    }

    func waitUntilReadyForExit(
        _ target: ClaudeUpdateTarget
    ) async throws -> ClaudeSessionInspection {
        let identity = try Self.applicationIdentity(target)
        let expectedSurfaceGeneration = try await localSurfaceGeneration(
            for: target,
            identity: identity
        )
        let events = await sessionRegistry.events(
            workspaceID: identity.workspaceID,
            panelID: identity.panelID,
            surfaceGeneration: expectedSurfaceGeneration
        )
        let initial = try await inspect(target)
        if let expectedSurfaceGeneration {
            guard await surfaceGenerationIsCurrent(
                identity,
                expected: expectedSurfaceGeneration
            ) else {
                throw UniConnectClaudeSessionControllerError.identityMismatch
            }
        }
        if initial.isIdle { return initial }

        let result = await withTaskGroup(of: InspectionWaitResult.self) { group in
            group.addTask { [weak self] in
                for await _ in events {
                    guard !Task.isCancelled, let self else { return .streamEnded }
                    if let expectedSurfaceGeneration,
                       !(await self.surfaceGenerationIsCurrent(
                           identity,
                           expected: expectedSurfaceGeneration
                       )) {
                        return .streamEnded
                    }
                    guard let inspection = try? await self.inspect(target), inspection.isIdle else {
                        continue
                    }
                    return .inspection(inspection)
                }
                return .streamEnded
            }
            group.addTask { [idleTimeout] in
                try? await Task.sleep(for: idleTimeout)
                return .timedOut
            }
            let first = await group.next() ?? .streamEnded
            group.cancelAll()
            return first
        }
        try Task.checkCancellation()
        guard case .inspection(let inspection) = result else {
            throw UniConnectClaudeSessionControllerError.timedOut
        }
        return inspection
    }

    func requestCleanExit(
        _ target: ClaudeUpdateTarget,
        expectedProcessID: Int32
    ) async throws {
        let fresh = try await inspect(target)
        guard fresh.processID == expectedProcessID, fresh.matches(target) else {
            throw UniConnectClaudeSessionControllerError.identityMismatch
        }
        guard fresh.isIdle else {
            throw UniConnectClaudeSessionControllerError.sessionNotIdle
        }

        switch target.host.kind {
        case .local:
            let identity = try Self.applicationIdentity(target)
            let sent = await terminalWriter.sendText(
                "/exit\r",
                workspaceID: identity.workspaceID,
                panelID: identity.panelID
            )
            guard sent else { throw UniConnectClaudeSessionControllerError.inputRejected }
        case .remote:
            try await remoteController.requestCleanExit(
                target,
                expectedProcessID: expectedProcessID
            )
        }
    }

    func waitForShellAfterExit(
        _ target: ClaudeUpdateTarget,
        exitedProcessID: Int32
    ) async throws {
        switch target.host.kind {
        case .local:
            try await waitForLocalShell(target, exitedProcessID: exitedProcessID)
        case .remote:
            try await remoteController.waitForShellAfterExit(
                target,
                exitedProcessID: exitedProcessID
            )
        }
    }

    func restore(_ target: ClaudeUpdateTarget, replacingProcessID: Int32?) async throws {
        if let current = try? await inspect(target),
           current.matches(target),
           let processID = current.processID,
           processID != replacingProcessID {
            return
        }
        switch target.host.kind {
        case .local:
            if let replacingProcessID {
                try await waitForLocalShell(target, exitedProcessID: replacingProcessID)
            }
            try await restoreLocal(target)
        case .remote:
            try await remoteController.restore(
                target,
                replacingProcessID: replacingProcessID
            )
        }
    }

    private func waitForLocalShell(
        _ target: ClaudeUpdateTarget,
        exitedProcessID: Int32
    ) async throws {
        let identity = try Self.applicationIdentity(target)
        let expectedSurfaceGeneration = try await requiredLocalSurfaceGeneration(identity)
        let events = await sessionRegistry.events(
            workspaceID: identity.workspaceID,
            panelID: identity.panelID,
            surfaceGeneration: expectedSurfaceGeneration
        )
        try await processExitWaiter.waitForExit(
            processID: exitedProcessID,
            timeout: shellTimeout
        )
        if await shellIsReady(identity, surfaceGeneration: expectedSurfaceGeneration) { return }

        let result = await withTaskGroup(of: ShellWaitResult.self) { group in
            group.addTask { [weak self] in
                for await event in events {
                    guard !Task.isCancelled, let self else { return .streamEnded }
                    guard case .local(let signal) = event,
                          signal.kind == .shellActivityChanged,
                          signal.shellActivity == Workspace.PanelShellActivityState.promptIdle.rawValue,
                          await self.shellIsReady(
                              identity,
                              surfaceGeneration: expectedSurfaceGeneration
                          ) else {
                        continue
                    }
                    return .ready
                }
                return .streamEnded
            }
            group.addTask { [shellTimeout] in
                try? await Task.sleep(for: shellTimeout)
                return .timedOut
            }
            let first = await group.next() ?? .streamEnded
            group.cancelAll()
            return first
        }
        try Task.checkCancellation()
        guard case .ready = result else {
            throw UniConnectClaudeSessionControllerError.shellUnavailable
        }
    }

    private func restoreLocal(_ target: ClaudeUpdateTarget) async throws {
        guard let binding = target.binding else {
            throw UniConnectClaudeSessionControllerError.invalidTarget
        }
        let identity = try Self.applicationIdentity(target)
        let expectedSurfaceGeneration = try await requiredLocalSurfaceGeneration(identity)
        guard await shellIsReady(identity, surfaceGeneration: expectedSurfaceGeneration),
              let wrapperPath = wrapperPathProvider(),
              FileManager.default.isExecutableFile(atPath: wrapperPath) else {
            throw UniConnectClaudeSessionControllerError.restoreUnavailable
        }
        let events = await sessionRegistry.events(
            workspaceID: identity.workspaceID,
            panelID: identity.panelID,
            surfaceGeneration: expectedSurfaceGeneration
        )
        let command = Self.localRestoreCommand(binding: binding, wrapperPath: wrapperPath)
        let sent = await terminalWriter.sendText(
            command + "\r",
            workspaceID: identity.workspaceID,
            panelID: identity.panelID
        )
        guard sent else { throw UniConnectClaudeSessionControllerError.inputRejected }

        let result = await withTaskGroup(of: InspectionWaitResult.self) { group in
            group.addTask { [weak self] in
                for await _ in events {
                    guard !Task.isCancelled, let self else { return .streamEnded }
                    guard let inspection = try? await self.inspect(target),
                          inspection.matches(target),
                          inspection.processID != nil else {
                        continue
                    }
                    return .inspection(inspection)
                }
                return .streamEnded
            }
            group.addTask { [restoreTimeout] in
                try? await Task.sleep(for: restoreTimeout)
                return .timedOut
            }
            let first = await group.next() ?? .streamEnded
            group.cancelAll()
            return first
        }
        try Task.checkCancellation()
        guard case .inspection = result else {
            throw UniConnectClaudeSessionControllerError.timedOut
        }
    }

    private func shellIsReady(
        _ identity: (workspaceID: UUID, panelID: UUID),
        surfaceGeneration: UUID
    ) async -> Bool {
        let panel = await stateReader.panelSnapshot(
            workspaceID: identity.workspaceID,
            panelID: identity.panelID
        )
        return panel?.surfaceGeneration == surfaceGeneration
            && panel?.shellActivity == Workspace.PanelShellActivityState.promptIdle.rawValue
    }

    private func localSurfaceGeneration(
        for target: ClaudeUpdateTarget,
        identity: (workspaceID: UUID, panelID: UUID)
    ) async throws -> UUID? {
        switch target.host.kind {
        case .local:
            return try await requiredLocalSurfaceGeneration(identity)
        case .remote:
            return nil
        }
    }

    private func requiredLocalSurfaceGeneration(
        _ identity: (workspaceID: UUID, panelID: UUID)
    ) async throws -> UUID {
        guard let generation = await stateReader.panelSnapshot(
            workspaceID: identity.workspaceID,
            panelID: identity.panelID
        )?.surfaceGeneration else {
            throw UniConnectClaudeSessionControllerError.identityMismatch
        }
        return generation
    }

    private func surfaceGenerationIsCurrent(
        _ identity: (workspaceID: UUID, panelID: UUID),
        expected: UUID
    ) async -> Bool {
        await stateReader.panelSnapshot(
            workspaceID: identity.workspaceID,
            panelID: identity.panelID
        )?.surfaceGeneration == expected
    }

    private static func applicationIdentity(
        _ target: ClaudeUpdateTarget
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        guard let workspaceID = UUID(uuidString: target.boxID),
              let panelID = UniConnectClaudeUpdateTargetIdentity.panelID(from: target.id) else {
            throw UniConnectClaudeSessionControllerError.invalidTarget
        }
        return (workspaceID, panelID)
    }

    private static func localRestoreCommand(
        binding: ClaudeSessionBinding,
        wrapperPath: String
    ) -> String {
        let cwd = UniConnectSSH.shellQuote(binding.workingDirectory)
        let executable = UniConnectSSH.shellQuote(binding.executablePath)
        let wrapper = UniConnectSSH.shellQuote(wrapperPath)
        let session = UniConnectSSH.shellQuote(binding.sessionID.uuidString.lowercased())
        return "cd -- \(cwd) && CMUX_CUSTOM_CLAUDE_PATH=\(executable) \(wrapper) --resume \(session) --dangerously-skip-permissions"
    }
}
