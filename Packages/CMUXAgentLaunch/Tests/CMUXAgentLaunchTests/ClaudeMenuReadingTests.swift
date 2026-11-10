import Foundation
import Testing
@testable import CMUXAgentLaunch

/// La confianza de carpeta llega con «No, exit» marcado: se elige por el texto, nunca por posición.
@Suite("Menús de Claude")
struct ClaudeMenuReadingTests {
    private let trust = """
     Accessing workspace:
     /private/tmp/x
     Quick safety check: Is this a project you created or one you trust? (Like your own code). If not,
     take a moment to review what's in this folder first.
     Claude Code'll be able to read, edit, and execute files here.
     Security guide
     ❯ No, exit
       Yes, I trust this folder
     Enter to confirm · Esc to cancel
    """

    @Test("La pregunta real de 2.1.321: hay que bajar una línea hasta «Yes, I trust this folder»")
    func trustQuestionNeedsOneDown() throws {
        let menu = try #require(ClaudeMenuReading(screen: trust, offering: "Yes, I trust this folder"))
        #expect(menu.options == ["No, exit", "Yes, I trust this folder"])
        #expect(!menu.isSelected("Yes, I trust this folder"))
        #expect(menu.moves(to: "Yes, I trust this folder") == 1)
        let moved = trust.replacingOccurrences(of: "❯ No, exit", with: "  No, exit")
            .replacingOccurrences(of: "  Yes, I trust", with: "❯ Yes, I trust")
        let after = try #require(ClaudeMenuReading(screen: moved, offering: "Yes, I trust this folder"))
        #expect(after.isSelected("Yes, I trust this folder"))
        #expect(after.moves(to: "Yes, I trust this folder") == 0)
    }

    @Test("Con números delante también se encuentra por el texto")
    func numberedOptions() throws {
        let screen = " Background work is running\n ❯ 1. Keep running in background\n   2. Exit and stop tasks\n"
        let menu = try #require(ClaudeMenuReading(screen: screen, offering: "Exit and stop tasks"))
        #expect(menu.moves(to: "Exit and stop tasks") == 1)
    }

    @Test("Sin marca, o sin la opción, no hay menú que tocar")
    func nothingToTouch() {
        #expect(ClaudeMenuReading(screen: "   No, exit\n   Yes, I trust this folder\n", offering: "Yes, I trust this folder") == nil)
        #expect(ClaudeMenuReading(screen: trust, offering: "Allow once") == nil)
    }
}
