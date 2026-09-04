import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect controlled process runner")
struct UniConnectControlledProcessRunnerTests {
    @Test("Runs an executable directly and captures bounded output")
    func capturesOutputWithoutShell() async throws {
        let runner = UniConnectControlledProcessRunner(maximumOutputBytes: 1_024)
        let result = try await runner.run(
            executable: "/usr/bin/printf",
            arguments: ["%s", "hello"],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: .seconds(2)
        )

        #expect(result.terminationStatus == 0)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "hello")
        #expect(result.standardError.isEmpty)
        #expect(!result.outputWasTruncated)
    }

    @Test("Caps output while continuing to drain the child pipe")
    func truncatesOversizedOutput() async throws {
        let runner = UniConnectControlledProcessRunner(maximumOutputBytes: 1_024)
        let result = try await runner.run(
            executable: "/usr/bin/printf",
            arguments: ["%s", String(repeating: "x", count: 8_192)],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: .seconds(2)
        )

        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput.count == 1_024)
        #expect(result.outputWasTruncated)
    }

    @Test("Terminates a child at its deadline")
    func enforcesTimeout() async {
        let runner = UniConnectControlledProcessRunner()
        await #expect(throws: UniConnectProcessRunnerError.timedOut) {
            try await runner.run(
                executable: "/bin/sleep",
                arguments: ["5"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: .milliseconds(30)
            )
        }
    }

    @Test("Cancellation terminates the child instead of abandoning it")
    func propagatesCancellation() async {
        let runner = UniConnectControlledProcessRunner()
        let task = Task {
            try await runner.run(
                executable: "/bin/sleep",
                arguments: ["5"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: .seconds(10)
            )
        }
        await Task.yield()
        task.cancel()

        await #expect(throws: UniConnectProcessRunnerError.cancelled) {
            try await task.value
        }
    }

    @Test("App shutdown synchronously terminates every owned child")
    func shutdownCancelsOwnedChild() async {
        let runner = UniConnectControlledProcessRunner()
        let task = Task {
            try await runner.run(
                executable: "/bin/sleep",
                arguments: ["5"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: .seconds(10)
            )
        }
        try? await Task.sleep(for: .milliseconds(50))

        runner.shutdown()

        await #expect(throws: (any Error).self) {
            try await task.value
        }
    }

    @Test("App shutdown rejects children registered after the shutdown boundary")
    func shutdownRejectsFutureChildren() async {
        let runner = UniConnectControlledProcessRunner()
        runner.shutdown()

        await #expect(throws: UniConnectProcessRunnerError.shutDown) {
            try await runner.run(
                executable: "/usr/bin/true",
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: .seconds(1)
            )
        }
    }

    @Test("Rejects shell-relative executables and NUL-bearing arguments")
    func rejectsAmbiguousRequests() async {
        let runner = UniConnectControlledProcessRunner()
        await #expect(throws: UniConnectProcessRunnerError.invalidRequest) {
            try await runner.run(
                executable: "printf",
                arguments: [],
                environment: [:],
                timeout: .seconds(1)
            )
        }
        await #expect(throws: UniConnectProcessRunnerError.invalidRequest) {
            try await runner.run(
                executable: "/usr/bin/printf",
                arguments: ["bad\0argument"],
                environment: [:],
                timeout: .seconds(1)
            )
        }
    }
}
