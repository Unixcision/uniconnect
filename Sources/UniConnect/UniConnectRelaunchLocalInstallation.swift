import CMUXAgentLaunch
import Foundation
import UniConnectClaudeUpdate

/// This Mac's Claude installations, for Actualizar Claude: their login, their version and the one
/// `claude update` each gets, outside any pane (`Process`, never a shell).
actor UniConnectRelaunchLocalInstallation {
    /// What one installation looks like before anything is closed.
    struct Status: Sendable, Equatable {
        let version: String?
        let loggedIn: Bool?
    }

    private let processRunner: any UniConnectProcessRunning
    private let ambientEnvironment: @Sendable () -> [String: String]
    private let host = ClaudeUpdateHostIdentity(kind: .local, id: UniConnectClaudeUpdateHostID.local, displayName: "Mac")

    init(
        processRunner: any UniConnectProcessRunning,
        ambientEnvironment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.processRunner = processRunner
        self.ambientEnvironment = ambientEnvironment
    }

    /// The updater for one installation, with the `PATH` its agent ran with.
    ///
    /// The app's own `PATH` is `/usr/bin:/bin:…`: an npm installation of Claude needs `npm` to
    /// update, and without it `claude update` fails (measured on this Mac, 10-11-2026).
    private func updater(path: String?) -> UniConnectClaudeBinaryUpdater {
        let environment = environment(path: path)
        return UniConnectClaudeBinaryUpdater(
            processRunner: processRunner, credentialResolver: { _ in nil }, ambientEnvironment: { environment }
        )
    }

    private func environment(path: String?) -> [String: String] {
        var environment = ambientEnvironment()
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = ["\(home)/.local/bin", "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let directories = (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        var seen: Set<String> = []
        environment["PATH"] = (directories + fallback).filter { seen.insert($0).inserted }.joined(separator: ":")
        environment["TERM"] = "dumb"
        return environment
    }

    /// The version and login of the installation at `launcherPath`.
    func status(launcherPath: String, path: String?) async -> Status {
        let version = try? await updater(path: path).installedVersion(on: host, executablePath: launcherPath)
        let environment = environment(path: path)
        let auth = try? await processRunner.run(
            executable: launcherPath, arguments: ["auth", "status"], environment: environment,
            standardInput: nil, timeout: .seconds(20)
        )
        let loggedIn = auth.flatMap { ClaudeAuthStatus(output: String(decoding: $0.standardOutput, as: UTF8.self)) }?.loggedIn
        return Status(version: version?.description, loggedIn: loggedIn)
    }

    /// Runs `claude update` once for the installation at `launcherPath`.
    ///
    /// - Parameters:
    ///   - launcherPath: The resolved launcher.
    ///   - path: The `PATH` its agent ran with.
    ///   - host: The installation's host as target keys spell it.
    /// - Returns: The outcome for `updates[]`.
    func update(launcherPath: String, path: String?, host reportHost: String) async -> RelaunchInstallationUpdate {
        let updater = updater(path: path)
        let from = try? await updater.installedVersion(on: host, executablePath: launcherPath)
        let command = try? await updater.update(on: host, executablePath: launcherPath)
        let to = try? await updater.installedVersion(on: host, executablePath: launcherPath)
        let status: Int32? = command.map { $0.didTimeOut ? -1 : $0.exitCode }
        return UniConnectRelaunchRemoteWorker.outcome(host: reportHost, status: status, from: from, to: to)
    }
}
