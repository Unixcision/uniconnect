@testable import CMUXAgentLaunch
import Foundation
import Testing

@Suite("Cross-platform agent resume catalogue")
struct AgentResumeCatalogTests {
    @Test("Bundled command syntax is usable for every existing provider")
    func bundledProviders() throws {
        let catalog = try AgentResumeCatalog()
        let expected: [String: [String]] = [
            "claude": ["claude", "--resume", "SID", "--model", "chosen"],
            "codex": ["codex", "resume", "SID", "--model", "chosen"],
            "grok": ["grok", "-r", "SID", "--model", "chosen"],
            "pi": ["pi", "--session", "SID", "--model", "chosen"],
            "omp": ["omp", "--session", "SID", "--model", "chosen"],
            "amp": ["amp", "threads", "continue", "--model", "chosen", "SID"],
            "cursor": ["cursor-agent", "--resume", "SID", "--model", "chosen"],
            "gemini": ["gemini", "--resume", "SID", "--model", "chosen"],
            "kiro": ["kiro-cli", "chat", "--resume-id", "SID", "--model", "chosen"],
            "antigravity": ["agy", "--conversation", "SID", "--model", "chosen"],
            "opencode": ["opencode", "--session", "SID", "--model", "chosen"],
            "rovodev": ["acli", "rovodev", "run", "--restore", "SID", "--model", "chosen"],
            "hermes-agent": ["hermes", "--model", "chosen", "--resume", "SID"],
            "copilot": ["copilot", "--resume", "SID", "--model", "chosen"],
            "codebuddy": ["codebuddy", "--resume", "SID", "--model", "chosen"],
            "factory": ["droid", "--resume", "SID", "--model", "chosen"],
            "qoder": ["qodercli", "--resume", "SID", "--model", "chosen"],
        ]
        #expect(Set(catalog.providers.keys) == Set(expected.keys))
        for (kind, argv) in expected {
            #expect(catalog.argv(kind: kind, sessionId: "SID", executable: argv[0], arguments: ["--model", "chosen"]) == argv)
        }
        #expect(catalog.argv(kind: "agy", sessionId: "SID", executable: "agy", arguments: []) == ["agy", "--conversation", "SID"])
    }

    @Test("Injected syntax drives the real resume builder while retaining its trust policy")
    func explicitCatalogue() throws {
        let data = Data(#"{"schemaVersion":1,"providers":{"codex":{"executable":"codex","resume":["{executable}","fixture-resume","{arguments}","{sessionId}"]}}}"#.utf8)
        let builder = try AgentResumeArgv(catalogData: data)
        #expect(builder.builtInKind(kind: "codex", sessionId: "SID", executablePath: nil,
                                    arguments: ["codex", "--model", "chosen"]) == ["codex", "fixture-resume", "--model", "chosen", "SID", "--yolo"])
        #expect(builder.builtInKind(kind: "grok", sessionId: "SID", executablePath: nil, arguments: ["grok"]) == nil)
    }

    @Test("Unknown schemas and malformed substitutions fail closed", arguments: [
        #"{"schemaVersion":2,"providers":{"codex":{"executable":"codex","resume":["{executable}","resume","{sessionId}","{arguments}"]}}}"#,
        #"{"schemaVersion":1,"providers":{"codex":{"executable":"codex","resume":["{executable}","resume","{sessionId}","{unknown}"]}}}"#,
        #"{"schemaVersion":1,"providers":{"codex":{"aliases":["codex"],"executable":"codex","resume":["{executable}","resume","{sessionId}","{arguments}"]}}}"#,
    ])
    func invalidCatalogue(json: String) {
        #expect(throws: (any Error).self) { try AgentResumeArgv(catalogData: Data(json.utf8)) }
    }

    @Test("Linux decoder returns the exact argv emitted by Swift for every provider")
    func pythonParity() throws {
        let catalog = try AgentResumeCatalog()
        let arguments = ["--model", "model with spaces", "--config", "key='quoted;value'"]
        var vectors: [Vector] = []
        for kind in catalog.providers.keys.sorted() {
            let provider = try #require(catalog.providers[kind])
            for executable in [provider.executable, "/opt/agent path/" + provider.executable] {
                let expected = try #require(catalog.argv(kind: kind, sessionId: "exact-session-ID", executable: executable, arguments: arguments))
                vectors.append(Vector(kind: kind, sessionId: "exact-session-ID", executable: executable, arguments: arguments, expected: expected))
            }
        }
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import json, sys
        from uniconnect.resume_catalog import AgentResumeCatalog
        catalog = AgentResumeCatalog()
        vectors = json.load(sys.stdin)
        for item in vectors:
            actual = catalog.resume_argv(item['kind'], item['sessionId'], item['arguments'], executable=item['executable'])
            assert actual == item['expected'], (item['kind'], actual, item['expected'])
        print(len(vectors))
        """]
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONPATH": repository.appendingPathComponent("linux").path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(vectors))
        try input.fileHandleForWriting.close()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: response, as: UTF8.self)))
        #expect(String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == String(vectors.count))
    }

    private struct Vector: Encodable {
        let kind: String
        let sessionId: String
        let executable: String
        let arguments: [String]
        let expected: [String]
    }
}
