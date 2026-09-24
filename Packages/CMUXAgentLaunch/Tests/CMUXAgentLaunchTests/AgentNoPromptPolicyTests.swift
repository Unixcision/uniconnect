import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Relanzar y recuperar van siempre sin preguntas, y la orden es la misma en Mac, Linux y el VPS.
@Suite("Política sin preguntas")
struct AgentNoPromptPolicyTests {
    private let claudeID = "473ed1de-4397-45ef-b00b-6b17fd7382b0"
    private let codexID = "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17"

    private func makePolicy() throws -> AgentNoPromptPolicy {
        try AgentNoPromptPolicy()
    }

    @Test("Cada caso del contrato da la misma argv, entorno, orden de shell y nombre")
    func everyContractCaseMatches() throws {
        // Forma: {version, casos: [{nombre, provider, display_name, session_id, cwd, as_root,
        // arguments?, argv, environment, command, no_prompt_verified}]}. `arguments` falta = [].
        let root = try ContractFixtures().object("agent-tree-v1/reanudar-comandos.json")
        let cases = try #require(root["casos"] as? [[String: Any]], "reanudar-comandos.json sin «casos»")
        #expect(!cases.isEmpty)
        let policy = try makePolicy()
        for entry in cases {
            let name = entry["nombre"] as? String ?? "?"
            let provider = try #require(entry["provider"] as? String, "\(name): provider")
            let sessionID = try #require(entry["session_id"] as? String, "\(name): session_id")
            let asRoot = try #require(entry["as_root"] as? Bool, "\(name): as_root")
            let cwd = entry["cwd"] as? String
            let arguments = (entry["arguments"] as? [String]) ?? []
            let resume = try #require(
                policy.resume(provider: provider, sessionID: sessionID, asRoot: asRoot, arguments: arguments),
                "\(name)"
            )
            let argv = try #require(entry["argv"] as? [String], "\(name): argv")
            let environment = try #require(entry["environment"] as? [String: String], "\(name): environment")
            let verified = try #require(entry["no_prompt_verified"] as? Bool, "\(name): no_prompt_verified")
            let command = try #require(entry["command"] as? String, "\(name): command")
            let displayName = try #require(entry["display_name"] as? String, "\(name): display_name")
            #expect(resume.argv == argv, "\(name)")
            #expect(resume.environment == environment, "\(name)")
            #expect(resume.noPromptVerified == verified, "\(name)")
            #expect(resume.shellLine(workingDirectory: cwd) == command, "\(name)")
            #expect(policy.displayName(provider: provider) == displayName, "\(name)")
            // Idempotente también con opciones conservadas.
            #expect(policy.applying(to: resume.argv, provider: provider, asRoot: asRoot) == resume, "\(name)")
        }
    }

    @Test("Claude como root lleva IS_SANDBOX y la bandera al final")
    func claudeAsRoot() throws {
        let resume = try #require(try makePolicy().resume(provider: "claude", sessionID: claudeID, asRoot: true))
        #expect(resume.argv == ["claude", "--resume", claudeID, "--dangerously-skip-permissions"])
        #expect(resume.environment == ["IS_SANDBOX": "1"])
        #expect(resume.noPromptVerified)
        #expect(
            resume.shellLine(workingDirectory: "/root/xunis")
                == "cd -- '/root/xunis' && IS_SANDBOX=1 claude --resume \(claudeID) --dangerously-skip-permissions"
        )
    }

    @Test("Claude sin root no exporta nada")
    func claudeWithoutRoot() throws {
        let resume = try #require(try makePolicy().resume(provider: "claude", sessionID: claudeID, asRoot: false))
        #expect(resume.environment.isEmpty)
        #expect(
            resume.shellLine(workingDirectory: "/Users/dani/Desktop/PROYECTOS/MULTIGRAM")
                == "cd -- '/Users/dani/Desktop/PROYECTOS/MULTIGRAM' && claude --resume \(claudeID) --dangerously-skip-permissions"
        )
    }

    @Test("Codex pone --yolo tras el ejecutable")
    func codexPrefix() throws {
        let resume = try #require(try makePolicy().resume(provider: "codex", sessionID: codexID, asRoot: true))
        #expect(resume.argv == ["codex", "--yolo", "resume", codexID])
        #expect(resume.environment.isEmpty)
        #expect(resume.shellLine(workingDirectory: "/home/u/multigram")
            == "cd -- '/home/u/multigram' && codex --yolo resume \(codexID)")
    }

    @Test("agy es el alias de Antigravity y viaja como agy")
    func antigravityAlias() throws {
        let policy = try makePolicy()
        let resume = try #require(policy.resume(provider: "agy", sessionID: "conv-1", asRoot: false))
        #expect(resume.argv == ["agy", "--dangerously-skip-permissions", "--conversation", "conv-1"])
        #expect(policy.wireProvider("antigravity") == "agy")
        #expect(policy.wireProvider("agy") == "agy")
        #expect(policy.wireProvider("codex") == "codex")
    }

    @Test("Grok se reanuda sin bandera y sin verificar")
    func grokIsNotVerified() throws {
        let policy = try makePolicy()
        let resume = try #require(policy.resume(provider: "grok", sessionID: "g-1", asRoot: true))
        #expect(resume.argv == ["grok", "-r", "g-1"])
        #expect(resume.environment.isEmpty)
        #expect(!resume.noPromptVerified)
        #expect(!policy.isVerified(provider: "grok"))
        #expect(policy.isVerified(provider: "claude"))
        #expect(policy.isVerified(provider: "agy"))
        #expect(!policy.isVerified(provider: "no-existe"))
    }

    @Test("Aplicar dos veces da lo mismo que una")
    func applyingIsIdempotent() throws {
        let policy = try makePolicy()
        for provider in ["claude", "codex", "antigravity", "grok"] {
            let base = try #require(policy.resume(provider: provider, sessionID: "abc", asRoot: true))
            let again = policy.applying(to: base.argv, provider: provider, asRoot: true)
            #expect(again == base, "\(provider)")
        }
    }

    @Test("Un codex con la bandera antigua queda con un único --yolo tras el ejecutable")
    func codexLegacyFlagIsReplaced() throws {
        let adjusted = try makePolicy().applying(
            to: ["codex", "resume", codexID, "--dangerously-bypass-approvals-and-sandbox", "--yolo", "-m", "gpt-5.4"],
            provider: "codex",
            asRoot: false
        )
        #expect(adjusted.argv == ["codex", "--yolo", "resume", codexID, "-m", "gpt-5.4"])
    }

    @Test("Las opciones de ventana van detrás del id")
    func windowOptionsFollowTheID() throws {
        let resume = try #require(try makePolicy().resume(
            provider: "codex", sessionID: codexID, asRoot: false, arguments: ["-C", "/home/u/mi carpeta"]
        ))
        #expect(resume.argv == ["codex", "--yolo", "resume", codexID, "-C", "/home/u/mi carpeta"])
        #expect(resume.shellLine(workingDirectory: "/home/u/it's")
            == "cd -- '/home/u/it'\\''s' && codex --yolo resume \(codexID) -C '/home/u/mi carpeta'")
    }

    @Test("Un id de conversación inválido no produce orden")
    func invalidSessionIDIsRejected() throws {
        let policy = try makePolicy()
        #expect(policy.resume(provider: "claude", sessionID: "", asRoot: false) == nil)
        #expect(policy.resume(provider: "claude", sessionID: "a b", asRoot: false) == nil)
        #expect(policy.resume(provider: "claude", sessionID: "$(rm)", asRoot: false) == nil)
        #expect(policy.resume(provider: "claude", sessionID: String(repeating: "a", count: 161), asRoot: false) == nil)
        #expect(policy.resume(provider: "no-existe", sessionID: "abc", asRoot: false) == nil)
    }

    @Test("Un catálogo con bandera sin guion o entorno inválido se rechaza", arguments: [
        #"{"suffix": ["dangerously-skip-permissions"]}"#,
        #"{"prefix": ["--{x}"]}"#,
        #"{"legacy": ["-"]}"#,
        #"{"rootEnvironment": {"is_sandbox": "1"}}"#,
        #"{"rootEnvironment": {"IS_SANDBOX": "1; rm -rf /"}}"#,
        #"{"rootEnvironment": {"IS_SANDBOX": ""}}"#,
    ])
    func invalidNoPromptIsRejected(noPrompt: String) {
        let data = Data(#"""
        {"schemaVersion": 1, "providers": {"claude": {"executable": "claude",
          "resume": ["{executable}", "--resume", "{sessionId}", "{arguments}"],
          "noPrompt": \#(noPrompt)}}}
        """#.utf8)
        #expect(throws: AgentResumeCatalog.CatalogError.invalidSchema) {
            _ = try AgentNoPromptPolicy(data: data)
        }
    }

    @Test("Un catálogo sin noPrompt sigue valiendo y no verifica nada")
    func catalogWithoutNoPrompt() throws {
        let data = Data(#"""
        {"schemaVersion": 1, "providers": {"claude": {"executable": "claude",
          "resume": ["{executable}", "--resume", "{sessionId}", "{arguments}"]}}}
        """#.utf8)
        let policy = try AgentNoPromptPolicy(data: data)
        let resume = try #require(policy.resume(provider: "claude", sessionID: "abc", asRoot: true))
        #expect(resume.argv == ["claude", "--resume", "abc"])
        #expect(!resume.noPromptVerified)
    }

    @Test("--yolo sustituye aprobación y sandbox, con valor separado o con igual, cortas incluidas")
    func codexSupersedesApprovalAndSandbox() throws {
        let policy = try makePolicy()
        let adjusted = policy.applying(
            to: ["codex", "-a", "never", "resume", codexID, "--sandbox=workspace-write", "-s", "read-only",
                 "--full-auto", "-a=on-request", "--ask-for-approval", "untrusted", "-m", "gpt-5"],
            provider: "codex",
            asRoot: false
        )
        #expect(adjusted.argv == ["codex", "--yolo", "resume", codexID, "-m", "gpt-5"])
        // Una bandera sustituida sin valor detrás no se come nada más.
        #expect(policy.applying(to: ["codex", "resume", codexID, "-s"], provider: "codex", asRoot: false).argv
            == ["codex", "--yolo", "resume", codexID])
        // Claude no tiene «supersedes»: sus opciones quedan como estaban.
        #expect(policy.applying(to: ["claude", "--resume", claudeID, "-a", "x"], provider: "claude", asRoot: false).argv
            == ["claude", "--resume", claudeID, "-a", "x", "--dangerously-skip-permissions"])
    }

    @Test("El nombre de cada proveedor sale del catálogo, y sin él se enseña su id")
    func displayNamesComeFromTheCatalog() throws {
        let policy = try makePolicy()
        #expect(policy.displayName(provider: "claude") == "Claude Code")
        #expect(policy.displayName(provider: "codex") == "Codex")
        #expect(policy.displayName(provider: "agy") == "Antigravity")
        #expect(policy.displayName(provider: "antigravity") == "Antigravity")
        #expect(policy.displayName(provider: "grok") == "Grok")
        #expect(policy.displayName(provider: "pi") == "pi")
        #expect(policy.displayName(provider: "no-existe") == "no-existe")
    }

    @Test("Un catálogo con «supersedes» o «displayName» inválidos se rechaza", arguments: [
        #""noPrompt": {"prefix": ["--yolo"], "supersedes": [{"flag": "sandbox", "takesValue": true}]}"#,
        #""noPrompt": {"prefix": ["--yolo"], "supersedes": [{"flag": "--yolo", "takesValue": false}]}"#,
        #""noPrompt": {"prefix": ["--yolo"], "supersedes": [{"flag": "-s", "takesValue": true}, {"flag": "-s", "takesValue": false}]}"#,
        #""noPrompt": {"prefix": ["--yolo"], "supersedes": [{"flag": "-s x", "takesValue": true}]}"#,
        #""noPrompt": {"prefix": ["--yolo"], "supersedes": [{"flag": "-s"}]}"#,
        #""displayName": "   ""#,
    ])
    func invalidSupersedesOrDisplayNameIsRejected(fragment: String) {
        let data = Data(#"""
        {"schemaVersion": 1, "providers": {"codex": {"executable": "codex",
          "resume": ["{executable}", "resume", "{sessionId}", "{arguments}"], \#(fragment)}}}
        """#.utf8)
        #expect(throws: (any Error).self) {
            _ = try AgentNoPromptPolicy(data: data)
        }
    }

    @Test("Relanzar Claude fuerza la bandera aunque la ventana no la trajera")
    func claudeRelaunchAlwaysAddsTheFlag() throws {
        let dialect = ClaudeRelaunchDialect(policy: try makePolicy())
        #expect(dialect.invocation(conversation: "abc", previousArgv: ["claude"])
            == ["claude", "--resume", "abc", "--dangerously-skip-permissions"])
        #expect(dialect.invocation(
            conversation: "abc",
            previousArgv: ["claude", "--dangerously-skip-permissions", "--model", "opus"]
        ) == ["claude", "--resume", "abc", "--model", "opus", "--dangerously-skip-permissions"])

        // Sin política cargada, la bandera literal entra una sola vez.
        let fallback = ClaudeRelaunchDialect(policy: nil)
        #expect(fallback.invocation(conversation: "abc", previousArgv: ["claude"])
            == ["claude", "--resume", "abc", "--dangerously-skip-permissions"])
        #expect(fallback.invocation(conversation: "abc", previousArgv: ["claude", "--dangerously-skip-permissions"])
            == ["claude", "--resume", "abc", "--dangerously-skip-permissions"])
    }
}
