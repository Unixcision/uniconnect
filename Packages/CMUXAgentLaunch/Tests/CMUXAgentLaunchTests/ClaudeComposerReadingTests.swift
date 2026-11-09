import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Escribir `/exit` e Intro sobre un borrador lo enviaría. Estas capturas son de Claude 2.1.321 en
/// un tmux de este Mac (`capture-pane -e -p`), recortadas.
@Suite("Compositor de Claude")
struct ClaudeComposerReadingTests {
    private let esc = "\u{1B}"
    private var rule: String { "\(esc)[38;5;244m" + String(repeating: "─", count: 60) + "\(esc)[39m" }
    private var footer: String {
        "\(esc)[39m  \(esc)[38;5;220m⏵⏵\(esc)[39m \(esc)[38;5;220mauto mode on\(esc)[38;5;246m (shift+tab to cycle)\(esc)[39m"
    }

    private func screen(_ composer: [String]) -> String {
        (["  Claude Code v2.1.321", rule] + composer + [rule, footer]).joined(separator: "\n")
    }

    @Test("La sugerencia atenuada es un compositor vacío")
    func dimSuggestionIsEmpty() {
        let split = screen(["\(esc)[39m❯ \(esc)[2mTry\(esc)[0m \(esc)[2m\"refactor\(esc)[0m \(esc)[2m<filepath>\"\(esc)[0m"])
        #expect(ClaudeComposerReading.read(styledText: split) == .empty)
        let joined = screen(["\(esc)[39m❯ \(esc)[2mTry \"refactor <filepath>\"\(esc)[0m"])
        #expect(ClaudeComposerReading.read(styledText: joined) == .empty)
        #expect(ClaudeComposerReading.read(styledText: screen(["❯ "])) == .empty)
    }

    @Test("El texto normal es un borrador, también en varias líneas")
    func plainTextIsDraft() {
        #expect(ClaudeComposerReading.read(styledText: screen(["\(esc)[39m❯ hola esto es un borrador"]))
            == .draft("hola esto es un borrador"))
        #expect(ClaudeComposerReading.read(styledText: screen(["❯ primera línea", "  segunda línea   ", "    sangrada"]))
            == .draft("primera línea\nsegunda línea\n  sangrada"))
    }

    @Test("El gris de la paleta también es sugerencia, y el mismo texto sin gris es borrador")
    func greyPaletteIsSuggestion() {
        #expect(ClaudeComposerReading.read(styledText: screen(["❯ \(esc)[38;5;246mTry \"fix lint errors\"\(esc)[39m"])) == .empty)
        #expect(ClaudeComposerReading.read(styledText: screen(["❯ Try \"fix lint errors\""])) == .draft("Try \"fix lint errors\""))
    }

    @Test("El menú de órdenes debajo no se confunde con el compositor")
    func slashMenuBelowIsNotTheComposer() {
        let text = (["", rule, "❯ /exit", rule, "  ❯ /exit                                 Exit the CLI",
                     "    /context                              Visualize current context usage"]).joined(separator: "\n")
        #expect(ClaudeComposerReading.read(styledText: text) == .draft("/exit"))
    }

    @Test("La pregunta de confianza no tiene compositor: no se escribe nada")
    func trustQuestionIsUnrecognised() {
        let text = [rule, " Accessing workspace:", " /tmp/x", "", " \(esc)[38;5;153m❯\(esc)[39m \(esc)[38;5;153mNo, exit\(esc)[39m",
                    "   Yes, I trust this folder", "", " Enter to confirm · Esc to cancel"].joined(separator: "\n")
        #expect(ClaudeComposerReading.read(styledText: text) == .unrecognised)
    }

    @Test("La caja antigua también se lee")
    func oldBox() {
        let box = ["╭" + String(repeating: "─", count: 40) + "╮", "│ > borrador viejo                 │",
                   "╰" + String(repeating: "─", count: 40) + "╯"].joined(separator: "\n")
        #expect(ClaudeComposerReading.read(styledText: box) == .draft("borrador viejo"))
        let empty = ["╭" + String(repeating: "─", count: 40) + "╮", "│ >                                │",
                     "╰" + String(repeating: "─", count: 40) + "╯"].joined(separator: "\n")
        #expect(ClaudeComposerReading.read(styledText: empty) == .empty)
    }
}
