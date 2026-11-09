import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Se reabre con las mismas opciones (lista blanca); lo demás se quita y se dice por su nombre.
@Suite("Opciones con las que vuelve Claude")
struct ClaudeLaunchOptionsTests {
    private let id = "57c82fdd-78cb-4a6d-8ef9-f80553c0493a"

    @Test("Las ventanas de este Mac vuelven igual: modelo, effort y sin preguntas")
    func macWindowsComeBackTheSame() {
        let options = ClaudeLaunchOptions(argv: [
            "claude", "--resume", "4eccd582-8862-42d3-b457-0de00ffe49cb", "--dangerously-skip-permissions",
            "--model", "fable[1m]", "--effort", "medium",
        ])
        #expect(options.dropped.isEmpty)
        #expect(options.resumeArgv(launcher: "claude", conversation: id)
            == ["claude", "--resume", id, "--dangerously-skip-permissions", "--model", "fable[1m]", "--effort", "medium"])
    }

    @Test("Lo que no está en la lista se quita con su valor, y se nombra sin él")
    func unknownOptionsAreDroppedByName() {
        let options = ClaudeLaunchOptions(argv: [
            "/root/.local/share/claude/versions/2.1.281", "--continue", "--system-prompt", "secreto", "--add-dir", "/a",
            "--add-dir=/b", "--experimental-foo", "-p", "haz cosas", "--verbose", "suelto",
        ])
        #expect(options.kept == ["--add-dir", "/a", "--add-dir=/b", "--verbose"])
        #expect(options.dropped == ["--system-prompt", "--experimental-foo", "-p", "<posicional>"])
    }

    @Test("Actualizar sustituye el modelo y el effort que tuviera, y solo esos")
    func updateReplacesModelAndEffort() throws {
        let options = ClaudeLaunchOptions(argv: ["claude", "--model", "opus[1m]", "--effort=high", "--chrome"])
        let updated = options.applying(try RelaunchUpdateOptions(model: "fable[1m]", effort: "medium"))
        #expect(updated.kept == ["--chrome", "--model", "fable[1m]", "--effort", "medium"])
        let onlyEffort = options.applying(try RelaunchUpdateOptions(model: nil, effort: "max"))
        #expect(onlyEffort.kept == ["--model", "opus[1m]", "--chrome", "--effort", "max"])
        #expect(onlyEffort.value(of: "--model") == "opus[1m]")
        #expect(options.applying(.unchanged) == options)
    }

    @Test("Se reabre con el lanzador estable, nunca con la ruta de versions/")
    func stableLauncher() {
        #expect(ClaudeLaunchOptions.stableLauncher(argv0: "/root/.local/share/claude/versions/2.1.281", executable: nil) == "claude")
        #expect(ClaudeLaunchOptions.stableLauncher(argv0: "claude", executable: "/root/.local/share/claude/versions/2.1.281") == "claude")
        #expect(ClaudeLaunchOptions.stableLauncher(argv0: "claude", executable: "/usr/local/lib/node_modules/x/claude.exe") == "claude")
        #expect(ClaudeLaunchOptions.stableLauncher(argv0: "/opt/claude/bin/claude", executable: nil) == "/opt/claude/bin/claude")
    }
}
