import Foundation
import Testing
@testable import UniConnectClaudeBridge

@Suite("Claude bridge remote script execution")
struct ClaudeBridgeRemoteScriptExecutionTests {
    @Test("Registration is idempotent and cleanup restores foreign settings byte for byte")
    func registerTwiceThenUnregister() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("uniconnect-bridge-script-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".claude", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: home) }

        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let original = Data("""
        {
          "theme": "dark",
          "hooks": {
            "Stop": [
              {
                "matcher": "",
                "hooks": [
                  {"type": "command", "command": "printf foreign", "timeout": 1}
                ]
              }
            ]
          },
          "custom": {"keep": true}
        }
        """.utf8)
        try original.write(to: settingsURL)

        let route = ClaudeBridgeRoute(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            workspaceID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            surfaceID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            credentialID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            hostLabel: "fixture.invalid",
            workspaceName: "Fixture",
            windowName: "Window",
            tmuxSession: "uc-fixture"
        )
        let plan = ClaudeBridgeRemoteIntegration.connectionPlan(
            route: route,
            installationID: String(repeating: "a", count: 32),
            localListenerPort: 49_321
        )

        try runRemoteShell(plan.remoteSetupCommand, home: home)
        let firstRegistration = try Data(contentsOf: settingsURL)
        let firstDocument = try #require(
            JSONSerialization.jsonObject(with: firstRegistration) as? [String: Any]
        )
        let hooks = try #require(firstDocument["hooks"] as? [String: Any])
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 2)
        #expect((hooks["Notification"] as? [[String: Any]])?.count == 1)
        #expect((hooks["UserPromptSubmit"] as? [[String: Any]])?.count == 1)
        #expect((hooks["SessionStart"] as? [[String: Any]])?.count == 1)
        #expect(firstRegistration.range(of: Data("printf foreign".utf8)) != nil)

        try runRemoteShell(plan.remoteSetupCommand, home: home)
        #expect(try Data(contentsOf: settingsURL) == firstRegistration)

        try runRemoteShell(plan.remoteCleanupCommand, home: home)
        #expect(try Data(contentsOf: settingsURL) == original)
        let routeFile = home
            .appendingPathComponent(".uniconnect/claude-bridge/v1/installations")
            .appendingPathComponent(String(repeating: "a", count: 32))
            .appendingPathComponent("\(route.id.uuidString.lowercased()).route.json")
        #expect(!fileManager.fileExists(atPath: routeFile.path))
    }

    private func runRemoteShell(_ command: String, home: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
