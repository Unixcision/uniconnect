import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Palabras de shell")
struct RelaunchShellWordsTests {
    @Test("Comillas como shlex.quote", arguments: [
        ("", "''"), ("claude", "claude"), ("fable[1m]", "'fable[1m]'"), ("a b", "'a b'"),
        ("it's", "'it'\"'\"'s'"), ("/usr/bin/x-y_z.1:2,3@4%5+6=7", "/usr/bin/x-y_z.1:2,3@4%5+6=7"),
        ("ñ", "'ñ'"),
    ])
    func quoteMatchesPython(_ word: String, _ quoted: String) {
        #expect(RelaunchShellWords.quote(word) == quoted)
    }

    @Test("Separa palabras y operadores y quita las comillas")
    func tokenizes() throws {
        let words = try #require(RelaunchShellWords(#"{ \builtin unalias -- 'unsetenv'; } >/dev/null 2>&1 || true && eval 'echo '\''hi'\''' < /dev/null && pwd -P >| /tmp/x"#))
        #expect(words.tokens == [
            .word("{"), .word("builtin"), .word("unalias"), .word("--"), .word("unsetenv"), .op(";"), .word("}"),
            .op(">"), .word("/dev/null"), .word("2"), .op(">"), .op("&"), .word("1"), .op("||"), .word("true"),
            .op("&&"), .word("eval"), .word("echo 'hi'"), .op("<"), .word("/dev/null"), .op("&&"),
            .word("pwd"), .word("-P"), .op(">|"), .word("/tmp/x"),
        ])
    }

    @Test("Comillas dobles con sus escapes, y una comilla abierta no se lee")
    func doubleQuotesAndUnterminated() throws {
        #expect(try #require(RelaunchShellWords(#"echo "a \"b\" \$c \x""#)).tokens == [.word("echo"), .word(#"a "b" $c \x"#)])
        #expect(RelaunchShellWords("echo 'abierta") == nil)
    }
}
