import Testing
@testable import UniConnectClaudeUpdate

@Suite("Claude update output parser")
struct ClaudeUpdateOutputParserTests {
    private let parser = ClaudeUpdateOutputParser()

    @Test func parsesSupportedVersionOutput() {
        let cases = [
            ("1.2.3 (Claude Code)", ClaudeVersion(major: 1, minor: 2, patch: 3)),
            ("claude v2.5", ClaudeVersion(major: 2, minor: 5, patch: 0)),
            (
                "Claude Code 3.4.5-beta.1",
                ClaudeVersion(major: 3, minor: 4, patch: 5, prerelease: "beta.1")
            ),
        ]

        for (output, expected) in cases {
            #expect(parser.parseVersion(output) == expected)
        }
    }

    @Test func provesARealVersionIncrease() {
        let assessment = parser.assess(
            command: ClaudeUpdateCommandResult(
                exitCode: 0,
                didTimeOut: false,
                standardOutput: "Update complete",
                standardError: ""
            ),
            before: ClaudeVersion(major: 1, minor: 0, patch: 0),
            after: ClaudeVersion(major: 1, minor: 1, patch: 0)
        )

        #expect(assessment.status == .updated)
        #expect(assessment.issue == nil)
    }

    @Test func acceptsEqualVersionsOnlyForExplicitAlreadyCurrentOutput() {
        let version = ClaudeVersion(major: 1, minor: 2, patch: 3)
        let explicit = parser.assess(
            command: ClaudeUpdateCommandResult(
                exitCode: 0,
                didTimeOut: false,
                standardOutput: "Claude Code is already up to date",
                standardError: ""
            ),
            before: version,
            after: version
        )
        let ambiguous = parser.assess(
            command: ClaudeUpdateCommandResult(
                exitCode: 0,
                didTimeOut: false,
                standardOutput: "Update command finished",
                standardError: ""
            ),
            before: version,
            after: version
        )

        #expect(explicit.status == .alreadyUpdated)
        #expect(ambiguous.status == .failed)
        #expect(ambiguous.issue == .updateUnverifiable)
    }

    @Test func timeoutAndNonzeroExitFailClosed() {
        let before = ClaudeVersion(major: 1, minor: 0, patch: 0)
        let after = ClaudeVersion(major: 2, minor: 0, patch: 0)
        let timedOut = parser.assess(
            command: ClaudeUpdateCommandResult(
                exitCode: 0,
                didTimeOut: true,
                standardOutput: "latest version",
                standardError: ""
            ),
            before: before,
            after: after
        )
        let nonzero = parser.assess(
            command: ClaudeUpdateCommandResult(
                exitCode: 1,
                didTimeOut: false,
                standardOutput: "",
                standardError: "failed"
            ),
            before: before,
            after: after
        )

        #expect(timedOut.issue == .updateTimedOut)
        #expect(nonzero.issue == .updateCommandFailed)
    }
}
