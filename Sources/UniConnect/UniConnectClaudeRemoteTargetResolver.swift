import Foundation
import UniConnectClaudeBridge
import UniConnectClaudeUpdate

/// Resolves exact SSH/tmux Claude identities using a read-only, bounded remote probe.
actor UniConnectClaudeRemoteTargetResolver:
    UniConnectClaudeRemoteTargetResolving,
    UniConnectClaudeRemoteSessionControlling
{
    typealias CredentialResolver = @Sendable (UUID) async -> String?
    typealias SignalProvider = @Sendable (UUID) async -> ClaudeBridgeSessionSignal?
    typealias EventProvider = @Sendable (UUID, UUID) async -> AsyncStream<UniConnectClaudeSessionEvent>

    enum ResolutionError: Error, Sendable, Equatable {
        case invalidInput
        case missingCredential
        case invalidSSH
        case probeFailed
        case malformedResponse
        case identityMismatch
        case sessionNotIdle
        case shellUnavailable
        case controlFailed
        case timedOut
    }

    private struct Payload: Decodable {
        let version: Int
        let sessionID: String
        let workingDirectory: String
        let runtimeCwd: String
        let executablePath: String
        let sessionName: String
        let windowIndex: Int
        let paneIndex: Int
        let paneID: String
        let processID: Int32
        let isIdle: Bool
        let recordSessionKind: String
        let recordActivityState: String
        let recordObservedAtMilliseconds: Int64

        enum CodingKeys: String, CodingKey {
            case version
            case sessionID = "session_id"
            case workingDirectory = "working_directory"
            case runtimeCwd = "runtime_cwd"
            case executablePath = "executable_path"
            case sessionName = "session_name"
            case windowIndex = "window_index"
            case paneIndex = "pane_index"
            case paneID = "pane_id"
            case processID = "process_id"
            case isIdle = "is_idle"
            case recordSessionKind = "record_session_kind"
            case recordActivityState = "record_activity_state"
            case recordObservedAtMilliseconds = "record_observed_at_ms"
        }
    }

    private struct TargetContext {
        let credentialID: UUID
        let endpointFingerprint: String
        let workspaceID: UUID
        let routeID: UUID
        let tmuxSession: String
        let binding: ClaudeSessionBinding
        let pane: ClaudeTmuxPaneIdentity
    }

    private enum RestoreWaitResult: Sendable {
        case restored
        case streamEnded
        case timedOut
    }

    private let processRunner: any UniConnectProcessRunning
    private let binaryUpdater: any ClaudeBinaryUpdating
    private let credentialResolver: CredentialResolver
    private let signalProvider: SignalProvider
    private let eventProvider: EventProvider
    private let installationID: String
    private let ambientEnvironment: @Sendable () -> [String: String]
    private let currentDate: @Sendable () -> Date
    private let signalMaximumAge: TimeInterval
    private let signalFutureTolerance: TimeInterval

    init(
        processRunner: any UniConnectProcessRunning,
        binaryUpdater: any ClaudeBinaryUpdating,
        credentialResolver: @escaping CredentialResolver,
        installationID: String,
        signalProvider: @escaping SignalProvider = { _ in nil },
        eventProvider: @escaping EventProvider = { _, _ in
            AsyncStream { continuation in continuation.finish() }
        },
        ambientEnvironment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        currentDate: @escaping @Sendable () -> Date = Date.init,
        signalMaximumAge: TimeInterval = 5 * 60,
        signalFutureTolerance: TimeInterval = 30
    ) {
        self.processRunner = processRunner
        self.binaryUpdater = binaryUpdater
        self.credentialResolver = credentialResolver
        self.installationID = installationID
        self.signalProvider = signalProvider
        self.eventProvider = eventProvider
        self.ambientEnvironment = ambientEnvironment
        self.currentDate = currentDate
        self.signalMaximumAge = signalMaximumAge
        self.signalFutureTolerance = signalFutureTolerance
    }

    func resolve(
        workspace: UniConnectClaudeUpdateWorkspaceSnapshot,
        panel: UniConnectClaudeUpdatePanelSnapshot
    ) async -> UniConnectClaudeRemoteTargetResolution? {
        try? await resolveThrowing(workspace: workspace, panel: panel)
    }

    func inspect(_ target: ClaudeUpdateTarget) async throws -> ClaudeSessionInspection {
        let context = try targetContext(target)
        let payload = try await probe(
            credentialID: context.credentialID,
            routeID: context.routeID,
            tmuxSession: context.tmuxSession,
            expectedPaneID: context.pane.paneID,
            expectedEndpointFingerprint: context.endpointFingerprint
        )
        try validate(
            payload: payload,
            expectedRouteID: context.routeID,
            expectedTmuxSession: context.tmuxSession,
            authenticatedSignal: await signalProvider(context.routeID)
        )
        try validate(payload: payload, matches: context)
        let version = try? await binaryUpdater.installedVersion(
            on: target.host,
            executablePath: context.binding.executablePath
        )
        return ClaudeSessionInspection(
            isClaudeProcess: true,
            isIdle: payload.isIdle,
            processID: payload.processID,
            sessionID: context.binding.sessionID,
            workingDirectory: context.binding.workingDirectory,
            executablePath: context.binding.executablePath,
            version: version
        )
    }

    func requestCleanExit(
        _ target: ClaudeUpdateTarget,
        expectedProcessID: Int32
    ) async throws {
        let context = try targetContext(target)
        let authenticatedSignal = await signalProvider(context.routeID)
        let payload = try await probe(
            credentialID: context.credentialID,
            routeID: context.routeID,
            tmuxSession: context.tmuxSession,
            expectedPaneID: context.pane.paneID,
            expectedEndpointFingerprint: context.endpointFingerprint
        )
        try validate(
            payload: payload,
            expectedRouteID: context.routeID,
            expectedTmuxSession: context.tmuxSession,
            authenticatedSignal: authenticatedSignal
        )
        try validate(payload: payload, matches: context)
        guard payload.isIdle, payload.processID == expectedProcessID else {
            throw ResolutionError.sessionNotIdle
        }
        let result = try await runRemote(
            credentialID: context.credentialID,
            arguments: controlArguments(
                context: context,
                expectedProcessID: expectedProcessID,
                recordObservedAtMilliseconds: payload.recordObservedAtMilliseconds
            ),
            script: Self.remoteExitScript,
            timeout: .seconds(12),
            expectedEndpointFingerprint: context.endpointFingerprint
        )
        guard result.terminationStatus == 0, !result.outputWasTruncated else {
            throw ResolutionError.controlFailed
        }
    }

    func waitForShellAfterExit(
        _ target: ClaudeUpdateTarget,
        exitedProcessID: Int32
    ) async throws {
        let context = try targetContext(target)
        let result = try await runRemote(
            credentialID: context.credentialID,
            arguments: [
                context.tmuxSession,
                context.pane.paneID,
                String(exitedProcessID),
            ],
            script: Self.remoteWaitForShellScript,
            timeout: .seconds(35),
            expectedEndpointFingerprint: context.endpointFingerprint
        )
        guard result.terminationStatus == 0, !result.outputWasTruncated else {
            throw ResolutionError.shellUnavailable
        }
    }

    func restore(_ target: ClaudeUpdateTarget, replacingProcessID: Int32?) async throws {
        if let inspection = try? await inspect(target),
           inspection.matches(target),
           let processID = inspection.processID,
           processID != replacingProcessID {
            return
        }
        if let replacingProcessID {
            try await waitForShellAfterExit(target, exitedProcessID: replacingProcessID)
        }
        let context = try targetContext(target)
        let events = await eventProvider(context.workspaceID, context.routeID)
        let result = try await runRemote(
            credentialID: context.credentialID,
            arguments: [
                context.tmuxSession,
                context.pane.paneID,
                context.binding.sessionID.uuidString.lowercased(),
                context.binding.workingDirectory,
                context.binding.executablePath,
            ],
            script: Self.remoteRestoreScript,
            timeout: .seconds(12),
            expectedEndpointFingerprint: context.endpointFingerprint
        )
        guard result.terminationStatus == 0, !result.outputWasTruncated else {
            throw ResolutionError.controlFailed
        }

        let waitResult = await withTaskGroup(of: RestoreWaitResult.self) { group in
            group.addTask { [weak self] in
                for await event in events {
                    guard !Task.isCancelled, let self else { return .streamEnded }
                    guard case .remote(let signal) = event,
                          signal.kind == .sessionStart,
                          UUID(uuidString: signal.sessionID) == context.binding.sessionID,
                          self.standardized(signal.cwd) == self.standardized(context.binding.workingDirectory),
                          signal.tmuxPane == context.pane.paneID else {
                        continue
                    }
                    guard let inspection = try? await self.inspect(target),
                          inspection.matches(target),
                          inspection.processID != nil else {
                        continue
                    }
                    return .restored
                }
                return .streamEnded
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(45))
                return .timedOut
            }
            let first = await group.next() ?? .streamEnded
            group.cancelAll()
            return first
        }
        try Task.checkCancellation()
        guard case .restored = waitResult else { throw ResolutionError.timedOut }
    }

    private func resolveThrowing(
        workspace: UniConnectClaudeUpdateWorkspaceSnapshot,
        panel: UniConnectClaudeUpdatePanelSnapshot
    ) async throws -> UniConnectClaudeRemoteTargetResolution {
        guard workspace.kind == .ssh,
              panel.workspaceID == workspace.id,
              let credentialID = workspace.credentialID,
              let tmuxSession = normalized(panel.tmuxSession),
              UniConnectSSH.sanitizedTmuxName(tmuxSession) == tmuxSession,
              installationID.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil else {
            throw ResolutionError.invalidInput
        }
        guard let authenticatedSignal = await signalProvider(panel.id) else {
            throw ResolutionError.identityMismatch
        }
        let payload = try await probe(
            credentialID: credentialID,
            routeID: panel.id,
            tmuxSession: tmuxSession,
            expectedPaneID: authenticatedSignal.tmuxPane,
            expectedEndpointFingerprint: nil
        )
        try validate(
            payload: payload,
            expectedRouteID: panel.id,
            expectedTmuxSession: tmuxSession,
            authenticatedSignal: authenticatedSignal
        )

        let binding = ClaudeSessionBinding(
            sessionID: UUID(uuidString: payload.sessionID)!,
            workingDirectory: payload.workingDirectory,
            executablePath: payload.executablePath,
            installationID: UniConnectClaudeInstallationIdentity.identifier(
                executablePath: payload.executablePath
            )
        )
        let pane = ClaudeTmuxPaneIdentity(
            sessionName: payload.sessionName,
            windowIndex: payload.windowIndex,
            paneIndex: payload.paneIndex,
            paneID: payload.paneID
        )
        return UniConnectClaudeRemoteTargetResolution(binding: binding, pane: pane)
    }

    private func probe(
        credentialID: UUID,
        routeID: UUID,
        tmuxSession: String,
        expectedPaneID: String,
        expectedEndpointFingerprint: String?
    ) async throws -> Payload {
        let result = try await runRemote(
            credentialID: credentialID,
            arguments: [
                installationID,
                routeID.uuidString.lowercased(),
                tmuxSession,
                expectedPaneID,
            ],
            script: Self.remoteProbe,
            timeout: .seconds(15),
            expectedEndpointFingerprint: expectedEndpointFingerprint
        )
        guard result.terminationStatus == 0,
              !result.outputWasTruncated,
              result.standardOutput.count <= 16_384,
              let payload = try? JSONDecoder().decode(Payload.self, from: result.standardOutput) else {
            throw ResolutionError.malformedResponse
        }
        return payload
    }

    private func runRemote(
        credentialID: UUID,
        arguments: [String],
        script: String,
        timeout: Duration,
        expectedEndpointFingerprint: String?
    ) async throws -> UniConnectProcessResult {
        guard let connectCommand = await credentialResolver(credentialID) else {
            throw ResolutionError.missingCredential
        }
        guard UniConnectSSH.validateConnectCommand(connectCommand) == nil,
              let sshSession = UniConnectSSH.detectedSession(fromConnectCommand: connectCommand) else {
            throw ResolutionError.invalidSSH
        }
        if let expectedEndpointFingerprint,
           UniConnectClaudeUpdateHostID.endpointFingerprint(for: sshSession)
            != expectedEndpointFingerprint {
            throw ResolutionError.identityMismatch
        }
        let remoteCommand = (["python3 -"] + arguments.map(UniConnectSSH.shellQuote))
            .joined(separator: " ")
        guard let invocation = UniConnectSSHProcessInvocation(
            session: sshSession,
            remoteCommand: remoteCommand,
            ambientEnvironment: ambientEnvironment()
        ) else {
            throw ResolutionError.invalidSSH
        }
        do {
            return try await processRunner.run(
                executable: invocation.executable,
                arguments: invocation.arguments,
                environment: invocation.environment,
                standardInput: Data(script.utf8),
                timeout: timeout
            )
        } catch UniConnectProcessRunnerError.timedOut {
            throw ResolutionError.timedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ResolutionError.probeFailed
        }
    }

    private func validate(
        payload: Payload,
        expectedRouteID: UUID,
        expectedTmuxSession: String,
        authenticatedSignal: ClaudeBridgeSessionSignal?
    ) throws {
        guard payload.version == 1,
              UUID(uuidString: payload.sessionID) != nil,
              isAbsoluteSafePath(payload.workingDirectory),
              isAbsoluteSafePath(payload.runtimeCwd),
              isAbsoluteSafePath(payload.executablePath),
              payload.sessionName == expectedTmuxSession,
              payload.windowIndex >= 0,
              payload.paneIndex >= 0,
              payload.paneID.range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil,
              payload.processID > 1 else {
            throw ResolutionError.malformedResponse
        }

        guard let authenticatedSignal else {
            throw ResolutionError.identityMismatch
        }
        let age = currentDate().timeIntervalSince(authenticatedSignal.occurredAt)
        let signalTimestampMilliseconds = Int64(
            (authenticatedSignal.occurredAt.timeIntervalSince1970 * 1_000).rounded()
        )
        let expectedActivity: String
        switch authenticatedSignal.kind {
        case .stop, .idlePrompt:
            expectedActivity = "idle"
        case .sessionStart, .userPromptSubmit:
            expectedActivity = "running"
        }
        guard authenticatedSignal.routeID == expectedRouteID,
              age <= signalMaximumAge,
              age >= -signalFutureTolerance,
              payload.recordSessionKind == "uuid",
              payload.recordActivityState == expectedActivity,
              payload.isIdle == (expectedActivity == "idle"),
              payload.recordObservedAtMilliseconds == signalTimestampMilliseconds,
              UUID(uuidString: authenticatedSignal.sessionID) == UUID(uuidString: payload.sessionID),
              standardized(authenticatedSignal.cwd) == standardized(payload.runtimeCwd),
              authenticatedSignal.tmuxPane == payload.paneID else {
            throw ResolutionError.identityMismatch
        }
    }

    private func validate(payload: Payload, matches context: TargetContext) throws {
        guard payload.processID > 1,
              UUID(uuidString: payload.sessionID) == context.binding.sessionID,
              standardized(payload.workingDirectory)
                == standardized(context.binding.workingDirectory),
              standardized(payload.executablePath)
                == standardized(context.binding.executablePath),
              payload.sessionName == context.pane.sessionName,
              payload.windowIndex == context.pane.windowIndex,
              payload.paneIndex == context.pane.paneIndex,
              payload.paneID == context.pane.paneID else {
            throw ResolutionError.identityMismatch
        }
    }

    private func targetContext(_ target: ClaudeUpdateTarget) throws -> TargetContext {
        guard target.host.kind == .remote,
              let credentialID = UniConnectClaudeUpdateHostID.credentialID(from: target.host.id),
              let endpointFingerprint = UniConnectClaudeUpdateHostID.endpointFingerprint(from: target.host.id),
              let workspaceID = UUID(uuidString: target.boxID),
              let routeID = UniConnectClaudeUpdateTargetIdentity.panelID(from: target.id),
              let binding = target.binding,
              let pane = target.pane,
              UniConnectSSH.sanitizedTmuxName(pane.sessionName) == pane.sessionName,
              pane.paneID.range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil else {
            throw ResolutionError.invalidInput
        }
        return TargetContext(
            credentialID: credentialID,
            endpointFingerprint: endpointFingerprint,
            workspaceID: workspaceID,
            routeID: routeID,
            tmuxSession: pane.sessionName,
            binding: binding,
            pane: pane
        )
    }

    private func controlArguments(
        context: TargetContext,
        expectedProcessID: Int32,
        recordObservedAtMilliseconds: Int64
    ) -> [String] {
        [
            installationID,
            context.routeID.uuidString.lowercased(),
            context.tmuxSession,
            context.pane.paneID,
            String(expectedProcessID),
            context.binding.sessionID.uuidString.lowercased(),
            context.binding.workingDirectory,
            context.binding.executablePath,
            String(recordObservedAtMilliseconds),
        ]
    }

    private func isAbsoluteSafePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 4_096
    }

    private nonisolated func standardized(_ value: String) -> String {
        (value as NSString).standardizingPath
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static let remoteExitScript = #"""
import json
import os
import re
import stat
import subprocess
import sys

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
INSTALL_RE = re.compile(r"^[0-9a-f]{32}$")
PANE_RE = re.compile(r"^%[0-9]+$")
MAX_FILE = 16 * 1024
MAX_ENV = 1024 * 1024


def abort():
    raise SystemExit(1)


def secure_record(path):
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > MAX_FILE:
            abort()
        if info.st_mode & 0o077:
            abort()
        with open(path, "rb") as handle:
            data = handle.read(MAX_FILE + 1)
        if len(data) > MAX_FILE:
            abort()
        record = json.loads(data.decode("utf-8"))
        if not isinstance(record, dict):
            abort()
        return record
    except Exception:
        abort()


def tmux_fields(target):
    separator = "\x1f"
    format_value = separator.join([
        "#{session_name}", "#{pane_id}", "#{pane_pid}", "#{pane_current_path}", "#{pane_dead}",
    ])
    try:
        result = subprocess.run(
            ["tmux", "display-message", "-p", "-t", target, "-F", format_value],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
        if result.returncode != 0 or len(result.stdout) > MAX_FILE:
            abort()
        parts = result.stdout.decode("utf-8", "strict").rstrip("\r\n").split(separator)
        if len(parts) != 5:
            abort()
        return parts
    except Exception:
        abort()


def process_values(pid):
    try:
        with open("/proc/%d/stat" % pid, "rt", encoding="utf-8", errors="strict") as handle:
            value = handle.read(8192)
        tail = value[value.rfind(")") + 2:].split()
        if len(tail) < 6:
            abort()
        stat_values = {"ppid": int(tail[1]), "pgrp": int(tail[2]), "tpgid": int(tail[5])}
        with open("/proc/%d/environ" % pid, "rb") as handle:
            environment_data = handle.read(MAX_ENV + 1)
        with open("/proc/%d/cmdline" % pid, "rb") as handle:
            argv_data = handle.read(MAX_ENV + 1)
        if len(environment_data) > MAX_ENV or len(argv_data) > MAX_ENV:
            abort()
        wanted = {
            b"CMUX_CLAUDE_PID", b"CMUX_AGENT_LAUNCH_KIND", b"CMUX_AGENT_LAUNCH_EXECUTABLE",
            b"CMUX_AGENT_LAUNCH_CWD", b"CLAUDE_CONFIG_DIR", b"PATH",
        }
        environment = {}
        for item in environment_data.split(b"\0"):
            key, separator, raw_value = item.partition(b"=")
            if separator and key in wanted:
                environment[key.decode("ascii")] = raw_value.decode("utf-8", "strict")
        argv = [item.decode("utf-8", "strict") for item in argv_data.split(b"\0") if item]
        runtime_cwd = os.readlink("/proc/%d/cwd" % pid)
        return stat_values, environment, argv, runtime_cwd
    except Exception:
        abort()


def explicit_session(argv):
    for index, argument in enumerate(argv):
        for option in ("--session-id", "--resume", "-r"):
            if argument == option and index + 1 < len(argv) and UUID_RE.fullmatch(argv[index + 1]):
                return argv[index + 1].lower()
            prefix = option + "="
            if argument.startswith(prefix) and UUID_RE.fullmatch(argument[len(prefix):]):
                return argument[len(prefix):].lower()
    return None


def looks_like_claude(environment, argv, pid):
    if (environment.get("CMUX_AGENT_LAUNCH_KIND") == "claude"
            and environment.get("CMUX_CLAUDE_PID") == str(pid)):
        return True
    if not argv:
        return False
    name = os.path.basename(argv[0]).lower()
    if name == "claude":
        return True
    if name not in ("node", "bun"):
        return False
    lowered = [argument.lower() for argument in argv[1:]]
    return any(
        os.path.basename(argument) == "claude" or "/.claude/" in argument
        or "/claude/versions/" in argument or "@anthropic-ai/claude-code" in argument
        for argument in lowered
    )


def launcher(environment, argv):
    options = [environment.get("CMUX_AGENT_LAUNCH_EXECUTABLE", "")]
    if argv and os.path.basename(argv[0]).lower() == "claude":
        options.append(argv[0])
    options.extend(
        os.path.join(directory, "claude")
        for directory in environment.get("PATH", "").split(os.pathsep)
        if directory and os.path.isabs(directory)
    )
    for option in options:
        if os.path.isabs(option) and os.path.isfile(option) and os.access(option, os.X_OK):
            return os.path.normpath(option)
    return None


def is_descendant(pid, ancestor):
    seen = set()
    current = pid
    while current > 1 and current not in seen:
        if current == ancestor:
            return True
        seen.add(current)
        try:
            with open("/proc/%d/stat" % current, "rt", encoding="utf-8", errors="strict") as handle:
                value = handle.read(8192)
            tail = value[value.rfind(")") + 2:].split()
            current = int(tail[1])
        except Exception:
            return False
    return False


if len(sys.argv) != 10 or not sys.platform.startswith("linux"):
    abort()
installation_id, route_id, session, expected_pane, pid_raw, session_id, cwd, executable, observed_raw = sys.argv[1:]
if (not INSTALL_RE.fullmatch(installation_id) or not UUID_RE.fullmatch(route_id)
        or not PANE_RE.fullmatch(expected_pane) or not UUID_RE.fullmatch(session_id)
        or not os.path.isabs(cwd) or not os.path.isabs(executable)):
    abort()
try:
    expected_pid = int(pid_raw)
    expected_observed_at = int(observed_raw)
except ValueError:
    abort()
if expected_pid <= 1 or expected_observed_at <= 0:
    abort()

record_path = os.path.join(
    os.path.expanduser("~"), ".uniconnect", "claude-bridge", "v1", "installations",
    installation_id, route_id.lower() + ".session.json",
)
record = secure_record(record_path)
session_name, pane_id, pane_pid_raw, pane_path, pane_dead = tmux_fields(expected_pane)
if session_name != session or pane_id != expected_pane or pane_dead != "0":
    abort()
try:
    pane_pid = int(pane_pid_raw)
except ValueError:
    abort()
if (record.get("version") != 1 or record.get("route_id") != route_id.lower()
        or record.get("session_kind") != "uuid"
        or record.get("activity_state") != "idle"
        or record.get("observed_at_ms") != expected_observed_at
        or str(record.get("session_id", "")).lower() != session_id.lower()
        or record.get("tmux_pane") != expected_pane
        or not isinstance(record.get("cwd"), str)
        or os.path.realpath(record["cwd"]) != os.path.realpath(pane_path)):
    abort()

stat_values, environment, argv, runtime_cwd = process_values(expected_pid)
if (stat_values["pgrp"] <= 0 or stat_values["pgrp"] != stat_values["tpgid"]
        or not is_descendant(expected_pid, pane_pid)
        or not looks_like_claude(environment, argv, expected_pid)
        or explicit_session(argv) not in (None, session_id.lower())
        or os.path.realpath(runtime_cwd) != os.path.realpath(pane_path)):
    abort()
observed_launcher = launcher(environment, argv)
if observed_launcher is None:
    abort()
try:
    if not os.path.samefile(observed_launcher, executable):
        abort()
except Exception:
    abort()
launch_cwd = environment.get("CMUX_AGENT_LAUNCH_CWD") or runtime_cwd
if os.path.realpath(launch_cwd) != os.path.realpath(cwd):
    abort()

# Close the final race against a UserPromptSubmit journal replacement.
record_again = secure_record(record_path)
if record_again != record:
    abort()
session_name_again, pane_id_again, _, pane_path_again, pane_dead_again = tmux_fields(expected_pane)
if (session_name_again != session or pane_id_again != expected_pane or pane_dead_again != "0"
        or os.path.realpath(pane_path_again) != os.path.realpath(pane_path)):
    abort()

for keys in (("-l", "/exit"), ("Enter",)):
    result = subprocess.run(
        ["tmux", "send-keys", "-t", expected_pane] + list(keys),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=2,
        check=False,
    )
    if result.returncode != 0:
        abort()
"""#

    private static let remoteWaitForShellScript = #"""
import os
import re
import select
import subprocess
import sys
import time

PANE_RE = re.compile(r"^%[0-9]+$")
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}


def abort():
    raise SystemExit(1)


def fields(target):
    separator = "\x1f"
    format_value = separator.join([
        "#{session_name}", "#{pane_id}", "#{pane_pid}", "#{pane_current_command}", "#{pane_dead}",
    ])
    try:
        result = subprocess.run(
            ["tmux", "display-message", "-p", "-t", target, "-F", format_value],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
        parts = result.stdout.decode("utf-8", "strict").rstrip("\r\n").split(separator)
        if result.returncode != 0 or len(parts) != 5:
            abort()
        return parts
    except Exception:
        abort()


def process_group(pid):
    try:
        with open("/proc/%d/stat" % pid, "rt", encoding="utf-8", errors="strict") as handle:
            value = handle.read(8192)
        tail = value[value.rfind(")") + 2:].split()
        return int(tail[2]), int(tail[5])
    except Exception:
        abort()


if len(sys.argv) != 4 or not sys.platform.startswith("linux"):
    abort()
session, expected_pane, pid_raw = sys.argv[1:]
if not session or not PANE_RE.fullmatch(expected_pane):
    abort()
try:
    expected_pid = int(pid_raw)
except ValueError:
    abort()
if expected_pid <= 1:
    abort()

before = fields(expected_pane)
if before[0] != session or before[1] != expected_pane or before[4] != "0":
    abort()
pane_pid = int(before[2])
if os.path.exists("/proc/%d" % expected_pid):
    descriptor = None
    try:
        pidfd_open = getattr(os, "pidfd_open", None)
        if pidfd_open is not None:
            descriptor = pidfd_open(expected_pid, 0)
            waiter = select.poll()
            waiter.register(descriptor, select.POLLIN)
            if not waiter.poll(30000):
                abort()
        else:
            deadline = time.monotonic() + 30.0
            while os.path.exists("/proc/%d" % expected_pid) and time.monotonic() < deadline:
                time.sleep(0.1)
            if os.path.exists("/proc/%d" % expected_pid):
                abort()
    except Exception:
        abort()
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except Exception:
                pass

after = fields(expected_pane)
if (after[0] != session or after[1] != expected_pane or after[2] != str(pane_pid)
        or after[4] != "0" or os.path.basename(after[3]).lower() not in SHELLS):
    abort()
pgrp, tpgid = process_group(pane_pid)
if pgrp <= 0 or pgrp != tpgid:
    abort()
"""#

    private static let remoteRestoreScript = #"""
import os
import re
import shlex
import stat
import subprocess
import sys

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
PANE_RE = re.compile(r"^%[0-9]+$")
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}


def abort():
    raise SystemExit(1)


if len(sys.argv) != 6 or not sys.platform.startswith("linux"):
    abort()
session, expected_pane, session_id, cwd, executable = sys.argv[1:]
if (not session or not PANE_RE.fullmatch(expected_pane) or not UUID_RE.fullmatch(session_id)
        or not os.path.isabs(cwd) or not os.path.isdir(cwd)
        or not os.path.isabs(executable) or not os.path.isfile(executable)
        or not os.access(executable, os.X_OK)):
    abort()

slug = cwd.replace("/", "-").replace(".", "-")
transcript = os.path.join(os.path.expanduser("~"), ".claude", "projects", slug, session_id + ".jsonl")
try:
    info = os.stat(transcript)
    if not stat.S_ISREG(info.st_mode) or info.st_size <= 0:
        abort()
except Exception:
    abort()

separator = "\x1f"
format_value = separator.join([
    "#{session_name}", "#{pane_id}", "#{pane_pid}", "#{pane_current_command}",
    "#{pane_current_path}", "#{pane_dead}",
])
try:
    result = subprocess.run(
        ["tmux", "display-message", "-p", "-t", expected_pane, "-F", format_value],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=2,
        check=False,
    )
    values = result.stdout.decode("utf-8", "strict").rstrip("\r\n").split(separator)
except Exception:
    abort()
if (result.returncode != 0 or len(values) != 6 or values[0] != session
        or values[1] != expected_pane or values[5] != "0"
        or os.path.basename(values[3]).lower() not in SHELLS):
    abort()
try:
    pane_pid = int(values[2])
    with open("/proc/%d/stat" % pane_pid, "rt", encoding="utf-8", errors="strict") as handle:
        process_stat = handle.read(8192)
    tail = process_stat[process_stat.rfind(")") + 2:].split()
    if int(tail[2]) <= 0 or int(tail[2]) != int(tail[5]):
        abort()
except Exception:
    abort()

markers = [
    "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS",
    "CLAUDE_CODE_SSE_PORT", "CLAUDE_PID", "CLAUDE_EFFORT",
]
command = (
    "unset " + " ".join(markers)
    + "; export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1; cd " + shlex.quote(cwd)
    + " && " + shlex.quote(executable) + " --resume " + shlex.quote(session_id.lower())
    + " --dangerously-skip-permissions"
)
for keys in (("-l", command), ("Enter",)):
    sent = subprocess.run(
        ["tmux", "send-keys", "-t", expected_pane] + list(keys),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=2,
        check=False,
    )
    if sent.returncode != 0:
        abort()
"""#

    private static let remoteProbe = #"""
import json
import os
import re
import stat
import subprocess
import sys

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
INSTALL_RE = re.compile(r"^[0-9a-f]{32}$")
PANE_RE = re.compile(r"^%[0-9]+$")
MAX_FILE = 16 * 1024
MAX_ENV = 1024 * 1024


def abort():
    raise SystemExit(1)


def bounded_regular_json(path):
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > MAX_FILE:
            return None
        if info.st_mode & 0o077:
            return None
        with open(path, "rb") as handle:
            data = handle.read(MAX_FILE + 1)
        if len(data) > MAX_FILE:
            return None
        value = json.loads(data.decode("utf-8"))
        return value if isinstance(value, dict) else None
    except Exception:
        return None


def run_tmux(target, format_value):
    try:
        result = subprocess.run(
            ["tmux", "display-message", "-p", "-t", target, "-F", format_value],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
        if result.returncode != 0 or len(result.stdout) > MAX_FILE:
            abort()
        return result.stdout.decode("utf-8", "strict").rstrip("\r\n")
    except Exception:
        abort()


def proc_stat(pid):
    try:
        with open("/proc/%d/stat" % pid, "rt", encoding="utf-8", errors="strict") as handle:
            value = handle.read(8192)
        tail = value[value.rfind(")") + 2:].split()
        if len(tail) < 6:
            return None
        return {
            "ppid": int(tail[1]),
            "pgrp": int(tail[2]),
            "tpgid": int(tail[5]),
        }
    except Exception:
        return None


def proc_environment(pid):
    try:
        path = "/proc/%d/environ" % pid
        size = os.stat(path).st_size
        if size > MAX_ENV:
            return None
        with open(path, "rb") as handle:
            data = handle.read(MAX_ENV + 1)
        if len(data) > MAX_ENV:
            return None
        selected = {}
        wanted = {
            b"CMUX_CLAUDE_PID",
            b"CMUX_AGENT_LAUNCH_KIND",
            b"CMUX_AGENT_LAUNCH_EXECUTABLE",
            b"CMUX_AGENT_LAUNCH_CWD",
            b"CLAUDE_CONFIG_DIR",
            b"PATH",
        }
        for item in data.split(b"\0"):
            key, separator, value = item.partition(b"=")
            if separator and key in wanted:
                selected[key.decode("ascii")] = value.decode("utf-8", "strict")
        return selected
    except Exception:
        return None


def proc_argv(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as handle:
            data = handle.read(MAX_ENV + 1)
        if len(data) > MAX_ENV:
            return None
        return [part.decode("utf-8", "strict") for part in data.split(b"\0") if part]
    except Exception:
        return None


def explicit_session(argv):
    options = ("--session-id", "--resume", "-r")
    for index, argument in enumerate(argv):
        for option in options:
            if argument == option and index + 1 < len(argv) and UUID_RE.fullmatch(argv[index + 1]):
                return argv[index + 1].lower()
            prefix = option + "="
            if argument.startswith(prefix) and UUID_RE.fullmatch(argument[len(prefix):]):
                return argument[len(prefix):].lower()
    return None


def transcript_exists(config_root, cwd, session_id):
    slug = cwd.replace("/", "-").replace(".", "-")
    path = os.path.join(config_root, "projects", slug, session_id + ".jsonl")
    try:
        info = os.stat(path)
        return stat.S_ISREG(info.st_mode) and info.st_size > 0
    except Exception:
        return False


def executable_file(path):
    return os.path.isabs(path) and os.path.isfile(path) and os.access(path, os.X_OK)


def resolve_claude_launcher(environment, argv):
    recorded = environment.get("CMUX_AGENT_LAUNCH_EXECUTABLE", "")
    if executable_file(recorded):
        return os.path.normpath(recorded)
    if argv and os.path.basename(argv[0]).lower() == "claude" and executable_file(argv[0]):
        return os.path.normpath(argv[0])
    for directory in environment.get("PATH", "").split(os.pathsep):
        if not directory or not os.path.isabs(directory):
            continue
        candidate = os.path.join(directory, "claude")
        if executable_file(candidate):
            return os.path.normpath(candidate)
    return None


def looks_like_claude(environment, argv, pid):
    if (environment.get("CMUX_AGENT_LAUNCH_KIND") == "claude"
            and environment.get("CMUX_CLAUDE_PID") == str(pid)):
        return True
    if not argv:
        return False
    executable_name = os.path.basename(argv[0]).lower()
    if executable_name == "claude":
        return True
    if executable_name not in ("node", "bun"):
        return False
    lowered = [argument.lower() for argument in argv[1:]]
    return any(
        os.path.basename(argument) == "claude"
        or "/.claude/" in argument
        or "/claude/versions/" in argument
        or "@anthropic-ai/claude-code" in argument
        for argument in lowered
    )


if len(sys.argv) != 5 or not sys.platform.startswith("linux"):
    abort()
installation_id, route_id, expected_session, expected_pane = sys.argv[1:]
if not INSTALL_RE.fullmatch(installation_id) or not UUID_RE.fullmatch(route_id):
    abort()
if (not expected_session or len(expected_session.encode("utf-8")) > 160
        or not PANE_RE.fullmatch(expected_pane)):
    abort()

separator = "\x1f"
format_value = separator.join([
    "#{session_name}", "#{window_index}", "#{pane_index}", "#{pane_id}",
    "#{pane_pid}", "#{pane_current_path}", "#{pane_current_command}", "#{pane_tty}",
])
parts = run_tmux(expected_pane, format_value).split(separator)
if len(parts) != 8:
    abort()
session_name, window_index, pane_index, pane_id, pane_pid, pane_path, pane_command, pane_tty = parts
if session_name != expected_session or pane_id != expected_pane:
    abort()
try:
    pane_pid_int = int(pane_pid)
    window_index_int = int(window_index)
    pane_index_int = int(pane_index)
except ValueError:
    abort()
if pane_pid_int <= 1 or window_index_int < 0 or pane_index_int < 0 or not os.path.isabs(pane_path):
    abort()

home = os.path.expanduser("~")
session_file = os.path.join(
    home, ".uniconnect", "claude-bridge", "v1", "installations",
    installation_id, route_id.lower() + ".session.json",
)
record = bounded_regular_json(session_file)
record_session = None
record_is_idle = False
record_session_kind = None
record_activity_state = None
record_observed_at = None
if record is not None:
    candidate_session = record.get("session_id")
    candidate_cwd = record.get("cwd")
    candidate_pane = record.get("tmux_pane")
    candidate_activity = record.get("activity_state")
    candidate_observed_at = record.get("observed_at_ms")
    if (record.get("version") == 1 and record.get("route_id") == route_id.lower()
            and record.get("session_kind") == "uuid"
            and isinstance(candidate_session, str) and UUID_RE.fullmatch(candidate_session)
            and isinstance(candidate_cwd, str) and os.path.isabs(candidate_cwd)
            and candidate_activity in ("idle", "running")
            and isinstance(candidate_observed_at, int) and candidate_observed_at > 0
            and candidate_pane == pane_id
            and os.path.realpath(candidate_cwd) == os.path.realpath(pane_path)):
        record_session = candidate_session.lower()
        record_is_idle = candidate_activity == "idle"
        record_session_kind = "uuid"
        record_activity_state = candidate_activity
        record_observed_at = candidate_observed_at

if record_session is None:
    abort()

stats = {}
children = {}
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    pid = int(entry)
    info = proc_stat(pid)
    if info is None:
        continue
    stats[pid] = info
    children.setdefault(info["ppid"], []).append(pid)

descendants = {pane_pid_int}
stack = [pane_pid_int]
while stack:
    parent = stack.pop()
    for child in children.get(parent, []):
        if child not in descendants:
            descendants.add(child)
            stack.append(child)

candidates = []
for pid in sorted(descendants):
    info = stats.get(pid)
    environment = proc_environment(pid)
    argv = proc_argv(pid)
    if info is None or environment is None or not argv:
        continue
    if not looks_like_claude(environment, argv, pid):
        continue
    if info["pgrp"] <= 0 or info["pgrp"] != info["tpgid"]:
        continue
    executable = resolve_claude_launcher(environment, argv)
    if executable is None:
        continue
    try:
        runtime_cwd = os.readlink("/proc/%d/cwd" % pid)
    except Exception:
        continue
    if os.path.realpath(runtime_cwd) != os.path.realpath(pane_path):
        continue
    launch_cwd = environment.get("CMUX_AGENT_LAUNCH_CWD") or runtime_cwd
    if not os.path.isabs(launch_cwd) or not os.path.isdir(launch_cwd):
        continue
    argv_session = explicit_session(argv)
    if argv_session is not None and record_session is not None and argv_session != record_session:
        continue
    session_id = argv_session or record_session
    if session_id is None:
        continue
    default_config_root = os.path.join(home, ".claude")
    config_root = environment.get("CLAUDE_CONFIG_DIR") or default_config_root
    # The update target model intentionally does not persist a custom Claude config
    # root. Fail closed instead of resolving a session we could not restore exactly.
    if (not os.path.isabs(config_root)
            or os.path.realpath(config_root) != os.path.realpath(default_config_root)
            or not transcript_exists(config_root, launch_cwd, session_id)):
        continue
    candidates.append({
        "version": 1,
        "session_id": session_id,
        "working_directory": os.path.normpath(launch_cwd),
        "runtime_cwd": os.path.normpath(runtime_cwd),
        "executable_path": os.path.normpath(executable),
        "session_name": session_name,
        "window_index": window_index_int,
        "pane_index": pane_index_int,
        "pane_id": pane_id,
        "process_id": pid,
        "is_idle": record_is_idle,
        "record_session_kind": record_session_kind,
        "record_activity_state": record_activity_state,
        "record_observed_at_ms": record_observed_at,
    })

if len(candidates) != 1:
    abort()
sys.stdout.write(json.dumps(candidates[0], ensure_ascii=False, separators=(",", ":")) + "\n")
"""#
}
