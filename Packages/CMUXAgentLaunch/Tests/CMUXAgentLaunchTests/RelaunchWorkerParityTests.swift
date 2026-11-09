import Foundation
import Testing
@testable import CMUXAgentLaunch

/// El Mac ejecuta por SSH el MISMO trabajador que Linux: misma petición, mismo arranque.
///
/// Las comparaciones las hace el propio cliente de Linux (`RelaunchAgents.request`) con un
/// transporte falso, y Python descomprime lo que comprimió Swift.
@Suite("Trabajador de Linux desde el Mac")
struct RelaunchWorkerParityTests {
    private var repository: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private func linux(_ path: String) throws -> Data {
        try Data(contentsOf: repository.appendingPathComponent(path))
    }

    private func source() throws -> RelaunchWorkerSource {
        RelaunchWorkerSource(
            catalogModule: String(decoding: try linux("linux/uniconnect/resume_catalog.py"), as: UTF8.self),
            worker: String(decoding: try linux("linux/uniconnect/relaunch_worker.py"), as: UTF8.self),
            identityHook: try linux("linux/uniconnect/agent_identity_hook.py"),
            recoveryScript: try? linux("linux/scripts/recovery.py")
        )
    }

    private func catalogProviders() throws -> Data {
        let catalog = try linux("Packages/CMUXAgentLaunch/Sources/CMUXAgentLaunch/Resources/agent-resume-v1.json")
        let object = try #require(try JSONSerialization.jsonObject(with: catalog) as? [String: Any])
        let providers = try #require(object["providers"])
        return try JSONSerialization.data(withJSONObject: providers)
    }

    private func python(_ program: String, input: Data) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", program]
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONPATH": repository.appendingPathComponent("linux").path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("zlib de ida y vuelta, con cabecera y suma Adler-32")
    func zlibRoundTrip() {
        let codec = RelaunchZlib()
        let data = Data((0..<5000).map { UInt8($0 % 251) })
        let stream = codec.compress(data)
        #expect(stream.prefix(2) == Data([0x78, 0xDA]))
        #expect(codec.decompress(stream) == data)
        var broken = stream
        broken[broken.count - 1] ^= 0xFF
        #expect(codec.decompress(broken) == nil)
    }

    @Test("La misma petición que RelaunchAgents.request, clave a clave, para inspect, start y status")
    func requestMatchesTheLinuxClient() throws {
        let source = try source()
        let proof = #"{"key":"linux:abc|gen:12","generation":12,"pane":{"pane":"%4","uid":0},"pid":7,"start":"99","effective_id":"57c82fdd-78cb-4a6d-8ef9-f80553c0493a","configuration":"d6","active":true,"warning":"tareas_de_fondo"}"#
        let operation = UUID(uuidString: "5d2e9a41-7c03-4b8e-a1f6-3e9b0c7d2a18")!
        let requests: [(String, RelaunchWorkerRequest)] = [
            ("inspect", .init(action: .inspect, session: "uc-prueba-relanzar", socket: "default", provider: "claude",
                              windowID: "d39a534f-70f4-43af-a906-4fe4be5f0da9", catalogProviders: try catalogProviders(),
                              verb: .agentRelaunch)),
            ("start", .init(action: .start, session: "uc-prueba-relanzar", socket: "default", provider: "claude",
                            windowID: "d39a534f-70f4-43af-a906-4fe4be5f0da9", catalogProviders: try catalogProviders(),
                            verb: .agentRelaunch, expected: Data(proof.utf8), operationID: operation)),
            ("status", .init(action: .status, session: "uc-prueba-relanzar", socket: "default", provider: "claude",
                             windowID: "d39a534f-70f4-43af-a906-4fe4be5f0da9", catalogProviders: try catalogProviders(),
                             expected: Data(proof.utf8), operationID: operation)),
        ]
        var commands: [String: String] = [:]
        for (name, request) in requests { commands[name] = try request.remoteCommand(source: source) }

        let program = """
        import base64, json, shlex, sys, zlib
        from uniconnect.relaunch_agents import RelaunchAgents
        mac = json.load(sys.stdin)
        proof = json.loads(mac["proof"])
        sent = []
        class Fake:
            def __init__(self, connection, socket_name=None): pass
            def run(self, script, timeout=None):
                sent.append(script)
                return type("R", (), {"stdout": "UC_RELAUNCH_V1 {}\\n"})()
        agents = RelaunchAgents(transport_factory=Fake)
        candidate = {"record": {"id": "d39a534f-70f4-43af-a906-4fe4be5f0da9", "tmux": "uc-prueba-relanzar",
                                "tmuxSocket": "default"}, "provider": "claude", "connection": "ssh x"}
        agents.request(candidate, "inspect", verb="agent.relaunch")
        agents.request(candidate, "start", verb="agent.relaunch", expected=proof, operation_id=mac["operation"])
        agents.request(candidate, "status", expected=proof, operation_id=mac["operation"])
        for name, script in zip(("inspect", "start", "status"), sent):
            outer = shlex.split(mac["commands"][name])
            assert outer[:2] == ["/bin/bash", "-lc"] and len(outer) == 3, outer[:2]
            words = shlex.split(outer[2])
            linux = shlex.split(script)
            assert words[:2] == linux[:2] == ["python3", "-c"] and len(words) == len(linux) == 4, name
            prefix, suffix = "import base64,zlib;exec(zlib.decompress(base64.b64decode('", "')))"
            assert words[2].startswith(prefix) and words[2].endswith(suffix), name
            inflated = zlib.decompress(base64.b64decode(words[2][len(prefix):-len(suffix)])).decode()
            assert inflated == agents.source, name
            ours, theirs = json.loads(base64.b64decode(words[3])), json.loads(base64.b64decode(linux[3]))
            if "identity_helper" in ours:
                assert zlib.decompress(base64.b64decode(ours.pop("identity_helper"))) == \\
                       zlib.decompress(base64.b64decode(theirs.pop("identity_helper"))), name
            assert ours == theirs, (name, sorted(set(ours) ^ set(theirs)))
        print("ok")
        """
        let input = try JSONSerialization.data(withJSONObject: [
            "commands": commands, "proof": proof, "operation": operation.uuidString.lowercased(),
        ])
        let (status, output) = try python(program, input: input)
        #expect(status == 0, Comment(rawValue: output))
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
    }

    @Test("Las opciones de Actualizar viajan; las de relanzar, nunca")
    func updateOptionsTravel() throws {
        let source = try source()
        let request = RelaunchWorkerRequest(
            action: .inspect, session: "s", socket: "default", provider: "claude", windowID: "w",
            catalogProviders: try catalogProviders(), verb: .agentUpdate,
            options: try RelaunchUpdateOptions(model: "fable[1m]", effort: "medium")
        )
        let object = try request.object(source: source)
        #expect(object["verb"] as? String == "agent.update")
        #expect(object["options"] as? [String: String] == ["model": "fable[1m]", "effort": "medium"])
        #expect(object["identity_helper"] == nil)
        #expect(RelaunchWorkerRequest.isValidTmuxName("uc-prueba-relanzar"))
        #expect(!RelaunchWorkerRequest.isValidTmuxName("uc prueba"))
    }
}
