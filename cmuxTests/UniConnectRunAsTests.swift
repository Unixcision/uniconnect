import CryptoKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `run-as.v1` on the Mac: the shared wrapper `subir.sh` as the pane's command, the host's side
/// of the switch (sudo's secret, su's paste, the diary's verdict), and what is saved.
@MainActor
@Suite(.serialized)
struct UniConnectRunAsTests {
    private static let password = " s3cr3t de dgomezm "
    private static let window = "0b5e8c2a-1d3f-4e5a-9b7c-8d6e5f4a3b2c"

    private func follower(_ host: FakeRunAsHost, deadline: Duration = .seconds(30)) -> UniConnectRunAsSwitch {
        UniConnectRunAsSwitch(
            host: host, sleep: { _ in try Task.checkCancellation() }, deadline: deadline
        )
    }

    @Test("The bundled wrapper is the contract's, and the pane command never carries the password")
    func paneCommand() throws {
        let wrapper = try #require(UniConnectRunAsWrapper())
        #expect(wrapper.script.contains("uc_method=$1 uc_user=$2 uc_id=$3 uc_inner=$4"))
        let plan = UniConnectRunAsPlan(
            runAs: try #require(UniConnectRunAs(mode: .root)), workingDirectory: "/srv/app",
            isSandbox: true, agentArgv: ["claude", "--dangerously-skip-permissions"]
        )
        let panel = try #require(UUID(uuidString: Self.window))
        let command = try #require(wrapper.paneCommand(runAs: plan.runAs, panelID: panel, inner: plan.innerCommand))
        #expect(command.hasPrefix("/bin/sh -c " + TerminalStartupShellQuoting.singleQuoted(wrapper.script)))
        #expect(command.hasSuffix(" uc-subir sudo 'root' \(Self.window) " + TerminalStartupShellQuoting.singleQuoted(plan.innerCommand)))
        #expect(!command.contains(Self.password))
        #expect(plan.innerCommand == "cd -- '/srv/app' && export IS_SANDBOX=1 && 'claude' '--dangerously-skip-permissions'; exec \"${SHELL:-/bin/sh}\" -l")
        // `current` never goes through the wrapper.
        #expect(wrapper.paneCommand(runAs: try #require(UniConnectRunAs(mode: .current)), panelID: panel, inner: "true") == nil)
        let su = try #require(UniConnectRunAs(mode: .user, method: .su, user: "deploy"))
        #expect(wrapper.paneCommand(runAs: su, panelID: panel, inner: "true")?.contains(" uc-subir su 'deploy' ") == true)
    }

    @Test("The diary gives each cause of the contract's table")
    func diaryCauses() {
        #expect(UniConnectRunAsJournal(diary: "UC_RUNAS_OK root\n") == .switched(user: "root"))
        #expect(UniConnectRunAsJournal(diary: "UC_RUNAS_WRONG nobody\nUC_RUNAS_END 97\n") == .failed(.wrongUser))
        #expect(UniConnectRunAsJournal(diary: "Sorry, try again.\nsudo: no password was provided\nUC_RUNAS_END 1\n") == .failed(.passwordIncorrect))
        #expect(UniConnectRunAsJournal(diary: "Password: su: Authentication failure\nUC_RUNAS_END 1\n") == .failed(.passwordIncorrect))
        #expect(UniConnectRunAsJournal(diary: "dgomezm is not in the sudoers file.\nUC_RUNAS_END 1\n") == .failed(.notAllowed))
        #expect(UniConnectRunAsJournal(diary: "sudo: unknown user fantasma\nUC_RUNAS_END 1\n") == .failed(.userNotFound))
        #expect(UniConnectRunAsJournal(diary: "su: user deploy does not exist\nUC_RUNAS_END 1\n") == .failed(.userNotFound))
        #expect(UniConnectRunAsJournal(diary: "something else\nUC_RUNAS_END 2\n") == .failed(.failed))
        #expect(UniConnectRunAsJournal(diary: "Password: ") == .awaitingPassword)
        #expect(UniConnectRunAsJournal(diary: "") == .running)
        // A refusal is only final once the wrapper has ended.
        #expect(UniConnectRunAsJournal(diary: "Sorry, try again.\n") == .running)
    }

    @Test("sudo: the password goes to the wrapper's secret before the session, never to the pane")
    func sudoSequence() async throws {
        let host = FakeRunAsHost(diaries: ["", "", "UC_RUNAS_OK root\n"])
        let switcher = follower(host)
        try await switcher.prepare(method: .sudo, password: Self.password, windowID: Self.window)
        #expect(await host.events == ["secret"])
        #expect(await host.secret == Self.password)
        #expect(await switcher.outcome(method: .sudo, password: Self.password, windowID: Self.window) == nil)
        #expect(await host.pasted == nil)
        #expect(await host.events == ["secret", "diary", "diary", "diary"])
    }

    @Test("su: the password is pasted once, only while su is the pane's question")
    func suSequence() async throws {
        let host = FakeRunAsHost(diaries: ["", "Password: ", "Password: ", "Password: \nUC_RUNAS_OK deploy\n"], suAsks: true)
        let switcher = follower(host)
        try await switcher.prepare(method: .su, password: Self.password, windowID: Self.window)
        #expect(await host.secret == nil)
        #expect(await switcher.outcome(method: .su, password: Self.password, windowID: Self.window) == nil)
        #expect(await host.pasted == Self.password)
        #expect(await host.events.filter { $0 == "paste" }.count == 1)

        // Something else asking for a password (not su's own question) never gets it.
        let impostor = FakeRunAsHost(diaries: ["Password: "], suAsks: false)
        #expect(await follower(impostor, deadline: .seconds(1)).outcome(method: .su, password: Self.password, windowID: Self.window) == .timeout)
        #expect(await impostor.pasted == nil)
    }

    @Test("A wrong user, a refused password and no answer are told apart; leftovers are removed")
    func failures() async throws {
        let wrong = FakeRunAsHost(diaries: ["UC_RUNAS_WRONG nobody\nUC_RUNAS_END 97\n"])
        #expect(await follower(wrong).outcome(method: .sudo, password: Self.password, windowID: Self.window) == .wrongUser)
        let refused = FakeRunAsHost(diaries: ["Sorry, try again.\n", "Sorry, try again.\nUC_RUNAS_END 1\n"])
        try await follower(refused).prepare(method: .sudo, password: "otra", windowID: Self.window)
        #expect(await follower(refused).outcome(method: .sudo, password: "otra", windowID: Self.window) == .passwordIncorrect)
        #expect(await refused.secret == nil)
        let silent = FakeRunAsHost(diaries: [])
        #expect(await follower(silent, deadline: .seconds(2)).outcome(method: .sudo, password: nil, windowID: Self.window) == .timeout)
    }

    @Test("IS_SANDBOX only when asked, always for Claude as root")
    func sandbox() throws {
        let root = try #require(UniConnectRunAs(mode: .root))
        let deploy = try #require(UniConnectRunAs(mode: .user, user: "deploy"))
        #expect(UniConnectWindowLaunch.effectiveSandbox(requested: false, agent: "claude", runAs: root))
        #expect(!UniConnectWindowLaunch.effectiveSandbox(requested: false, agent: "codex", runAs: root))
        #expect(!UniConnectWindowLaunch.effectiveSandbox(requested: false, agent: "claude", runAs: deploy))
        #expect(UniConnectWindowLaunch.effectiveSandbox(requested: true, agent: "codex", runAs: deploy))
        let plain = UniConnectRunAsPlan(runAs: deploy, workingDirectory: nil, isSandbox: false, agentArgv: ["codex", "--yolo"])
        #expect(!plain.innerCommand.contains("IS_SANDBOX"))
        // A plain terminal can switch user too, and never exports IS_SANDBOX.
        let shell = UniConnectRunAsPlan(runAs: root, workingDirectory: "/srv", isSandbox: true, agentArgv: nil)
        #expect(shell.innerCommand == "cd -- '/srv'; exec \"${SHELL:-/bin/sh}\" -l")
    }

    @Test("A Claude window as root starts on a conversation id chosen at creation, with IS_SANDBOX")
    func claudeAsRootPlan() throws {
        var request = try #require(UniConnectNewLocalWindowRequest(
            visibleName: "CLAUDE ROOT", boxRoot: "/srv/app", launchTarget: .claude
        ))
        request.runAs = UniConnectRunAs(mode: .root)
        #expect(request.effectiveSandbox)
        #expect(request.switchesUser)
        let session = "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b"
        let plan = try #require(UniConnectCoordinator.runAsPlan(request: request, workingDirectory: "/srv/app", sessionID: session))
        #expect(plan.isSandbox)
        #expect(plan.agentArgv?.suffix(2) == ["--session-id", session])
        let plain = try #require(UniConnectNewLocalWindowRequest(visibleName: nil, boxRoot: "/srv/app", launchTarget: .codex))
        #expect(UniConnectCoordinator.runAsPlan(request: plain, workingDirectory: "/srv/app", sessionID: nil) == nil)
    }

    @Test("The window saves run_as (window level) and the agent's IS_SANDBOX, never the password")
    func savedStateHasNoPassword() throws {
        let runAs = try #require(UniConnectRunAs(mode: .root))
        let launch = UniConnectWindowLaunch(agent: "claude", isSandbox: true, sessionID: "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b")
        let record = UniConnectLocalWindowRecord(id: UUID(), boxRoot: "/srv/app", runAs: runAs, launch: launch)
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(encoded.contains("\"runAs\""))
        #expect(encoded.contains("\"isSandbox\":true"))
        #expect(!encoded.contains(Self.password))
        #expect(!encoded.lowercased().contains("password"))
        let decoded = try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: Data(encoded.utf8))
        #expect(decoded.runAs == runAs)
        #expect(decoded.launch == launch)
        #expect(launch.environment == ["IS_SANDBOX": "1"])
        let shellOnly = UniConnectLocalWindowRecord(id: UUID(), boxRoot: "/srv/app", runAs: runAs)
        #expect(shellOnly.launch == nil)
        #expect(shellOnly.runAs == runAs)
    }

    @Test("The wire run_as of the contract examples parses, and bad ones do not")
    func wireParsing() throws {
        let root = try #require(UniConnectRunAs(wire: ["mode": "root", "method": "sudo", "password": "x"]))
        #expect(root == UniConnectRunAs(mode: .root, method: .sudo))
        #expect(root.targetUser == "root")
        let deploy = try #require(UniConnectRunAs(wire: ["mode": "user", "method": "su", "user": "deploy"]))
        #expect(deploy.targetUser == "deploy")
        #expect(UniConnectRunAs(wire: ["mode": "user"]) == nil)
        #expect(UniConnectRunAs(wire: ["mode": "user", "user": "a;rm -rf /"]) == nil)
        #expect(UniConnectRunAs(wire: ["mode": "admin"]) == nil)
        #expect(UniConnectRunAs(wire: ["mode": "root", "method": "doas"]) == nil)
    }

    @Test("The password store keeps it sealed, per window, and forgets it on close")
    func passwordStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniConnectRunAs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("run-as.vault")
        let key = SymmetricKey(size: .bits256)
        let store = UniConnectRunAsPasswordStore(storageURL: file, keyProvider: { key })
        let window = UUID()
        try await store.store(Self.password, for: window)
        let sealed = try Data(contentsOf: file)
        #expect(!String(decoding: sealed, as: UTF8.self).contains(Self.password))
        let reopened = UniConnectRunAsPasswordStore(storageURL: file, keyProvider: { key })
        #expect(try await reopened.password(for: window) == Self.password)
        try await reopened.remove(for: window)
        #expect(try await reopened.password(for: window) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

/// The machine side of a switch, scripted: each reading of the diary returns the next text.
private actor FakeRunAsHost: UniConnectRunAsHost {
    private(set) var events: [String] = []
    private(set) var secret: String?
    private(set) var pasted: String?
    private var diaries: [String]
    private let suAsks: Bool

    init(diaries: [String], suAsks: Bool = false) {
        self.diaries = diaries
        self.suAsks = suAsks
    }

    func writeSecret(_ password: String, windowID: String) async throws {
        events.append("secret")
        secret = password
    }

    func removeSecret(windowID: String) async {
        secret = nil
    }

    func diary(windowID: String) async -> String? {
        events.append("diary")
        guard let next = diaries.first else { return nil }
        if diaries.count > 1 { diaries.removeFirst() }
        return next
    }

    func suIsAsking(windowID: String) async -> Bool { suAsks }

    func pastePassword(_ password: String, windowID: String) async throws {
        events.append("paste")
        pasted = password
    }
}
