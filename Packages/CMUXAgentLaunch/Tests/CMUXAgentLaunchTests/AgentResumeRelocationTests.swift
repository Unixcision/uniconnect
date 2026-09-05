@testable import CMUXAgentLaunch
import Foundation
import Testing

@Suite("Deployed agent resume resources")
struct AgentResumeRelocationTests {
    @Test("A relocated standalone CLI uses only its deployed resource on both platforms")
    func relocatedExecutable() throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("uc-resume-relocated-" + UUID().uuidString)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let scratch = temporary.appendingPathComponent("fixture-build")
        // A separate scratch directory avoids the enclosing swift test's build
        // lock; this CLI is built once, and adds no product to the real package.
        let arguments = ["swift", "build", "--package-path", package.path, "--scratch-path", scratch.path,
                         "--product", "AgentResumeProbe", "--jobs", "2"]
        _ = try execute(URL(fileURLWithPath: "/usr/bin/env"), arguments: arguments)
        let output = try execute(URL(fileURLWithPath: "/usr/bin/env"), arguments: arguments + ["--show-bin-path"])
        let products = URL(fileURLWithPath: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let fixture = products.appendingPathComponent("AgentResumeProbe")
        let sourceBundle = try #require(["CMUXAgentLaunch_CMUXAgentLaunch.bundle", "CMUXAgentLaunch_CMUXAgentLaunch.resources"]
            .map { products.appendingPathComponent($0) }.first { fileManager.fileExists(atPath: $0.path) })
        for layout in ["adjacent", "app-cli"] {
            try checkLayout(layout, temporary: temporary, fixture: fixture, sourceBundle: sourceBundle)
        }
    }

    private func checkLayout(_ layout: String, temporary: URL, fixture: URL, sourceBundle: URL) throws {
        let fileManager = FileManager.default
        let directory = layout == "app-cli"
            ? temporary.appendingPathComponent("Renamed App.app/Contents/Resources/bin")
            : temporary.appendingPathComponent("standalone")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("resume-probe")
        try fileManager.copyItem(at: fixture, to: executable)
        let resourceRoot = layout == "app-cli" ? directory.deletingLastPathComponent() : directory
        let deployedBundle = resourceRoot.appendingPathComponent(sourceBundle.lastPathComponent)
        try fileManager.copyItem(at: sourceBundle, to: deployedBundle)
        let deployedResource = try #require(Bundle(url: deployedBundle)?.url(forResource: "agent-resume-v1", withExtension: "json"))
        // Give only the fixture a distinct executable token, so the test cannot
        // pass by finding the original resource through a baked-in build path.
        var catalogue = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: deployedResource)) as? [String: Any])
        var providers = try #require(catalogue["providers"] as? [String: [String: Any]])
        providers["codex"]?["executable"] = "relocated-codex"
        catalogue["providers"] = providers
        try JSONSerialization.data(withJSONObject: catalogue).write(to: deployedResource)
        try runProbe(executable: executable, expected: "relocated-codex")
        try fileManager.removeItem(at: deployedResource)
        try runProbe(executable: executable, expected: nil)
        try fileManager.removeItem(at: deployedBundle)
        try runProbe(executable: executable, expected: nil)
    }

    private func runProbe(executable: URL, expected: String?) throws {
        let response = try execute(executable, arguments: [])
        let argv = try JSONDecoder().decode([String]?.self, from: response)
        #expect(argv == expected.map { [$0, "resume", "SID", "--yolo"] })
    }

    private func execute(_ executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SWIFT_BACKTRACE"] = "interactive=no,timeout=0s"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: response, as: UTF8.self)
        try #require(process.terminationStatus == 0, Comment(rawValue: text))
        return response
    }
}
