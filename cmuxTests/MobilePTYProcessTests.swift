import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Each fixture is a fresh shell on a private PTY, with no tmux server or user files.
@Suite("Mobile native PTY", .timeLimit(.minutes(1)))
struct MobilePTYProcessTests {
    private let environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "TMPDIR": "/tmp"]

    @Test("The child owns a controlling terminal and receives its initial dimensions")
    func controllingTerminalAndDimensions() async throws {
        let process = MobilePTYProcess(environment: environment)
        let events = try await process.start(
            command: "test -t 0 && test -t 1 && test -t 2 && : </dev/tty || exit 91; /bin/stty size; printf '\\033[31mcolor\\033[0m\\n'; exit 7",
            columns: 93,
            rows: 37
        )
        let result = await collect(events)
        await process.close()
        #expect(result.status == 7)
        #expect(result.failures.isEmpty)
        #expect(result.text.contains("37 93"))
        #expect(result.bytes.range(of: Data("\u{1b}[31mcolor\u{1b}[0m".utf8)) != nil)
        #expect(result.largestChunk <= 64 * 1024)
    }

    @Test("Input reaches the same PTY and resize updates the live child")
    func inputAndLiveResize() async throws {
        let process = MobilePTYProcess(environment: environment)
        let events = try await process.start(
            command: "printf 'READY\\n'; IFS= read -r line; printf 'VALUE:%s\\n' \"$line\"; /bin/stty size",
            columns: 80,
            rows: 24
        )
        var output = Data()
        var sent = false
        var status: Int32?
        for await event in events {
            switch event {
            case .bytes(let data):
                output.append(data)
                if !sent && String(decoding: output, as: UTF8.self).contains("READY") {
                    sent = true
                    try await process.resize(columns: 121, rows: 43)
                    try await process.write(Data("móvil\n".utf8))
                }
            case .exited(let code): status = code
            case .failed(let error): Issue.record("Unexpected PTY failure: \(error)")
            case .geometry: Issue.record("Raw PTY processes must not decode tmux metadata")
            }
        }
        await process.close()
        #expect(status == 0)
        #expect(String(decoding: output, as: UTF8.self).contains("VALUE:móvil"))
        #expect(String(decoding: output, as: UTF8.self).contains("43 121"))
    }

    @Test("The command is absent from the shell's process arguments")
    func commandUsesPrivatePipe() async throws {
        let process = MobilePTYProcess(environment: environment)
        let secret = UUID().uuidString
        let events = try await process.start(
            command: "private_value='\(secret)'; /bin/ps -p $$ -o command=; printf 'DONE\\n'",
            columns: 80,
            rows: 24
        )
        let result = await collect(events)
        await process.close()
        #expect(result.status == 0)
        #expect(result.failures.isEmpty)
        #expect(result.text.contains("/dev/fd/3"))
        #expect(!result.text.contains(secret))
    }

    @Test("Raw terminal input preserves binary bytes")
    func rawBinaryRoundTrip() async throws {
        let process = MobilePTYProcess(environment: environment)
        let events = try await process.start(
            command: "/bin/stty raw -echo; printf READY; /bin/dd bs=4 count=1 2>/dev/null",
            columns: 80,
            rows: 24
        )
        let payload = Data([0x00, 0xff, 0x1b, 0x7f])
        var bytes = Data()
        var sent = false
        var status: Int32?
        for await event in events {
            switch event {
            case .bytes(let data):
                bytes.append(data)
                if !sent && bytes.range(of: Data("READY".utf8)) != nil {
                    sent = true
                    try await process.write(payload)
                }
            case .exited(let code): status = code
            case .failed(let error): Issue.record("Unexpected PTY failure: \(error)")
            case .geometry: Issue.record("Raw PTY processes must not decode tmux metadata")
            }
        }
        await process.close()
        #expect(status == 0)
        #expect(bytes.suffix(payload.count) == payload)
    }

    @Test("Input overflow emits a terminal error and rejects subsequent writes")
    func inputOverflowClosesConnection() async throws {
        let process = MobilePTYProcess(environment: environment, maximumInputBytes: 8)
        let events = try await process.start(command: "IFS= read -r line", columns: 80, rows: 24)
        await #expect(throws: MobilePTYProcessError.inputOverflow) {
            try await process.write(Data(repeating: 65, count: 9))
        }
        let result = await collect(events)
        #expect(result.failures == [.inputOverflow])
        await #expect(throws: MobilePTYProcessError.notRunning) {
            try await process.write(Data([65]))
        }
        await process.close()
    }

    @Test("Closing one client leaves an independently owned PTY usable")
    func closeIsIsolatedAndIdempotent() async throws {
        let first = MobilePTYProcess(environment: environment)
        let second = MobilePTYProcess(environment: environment)
        let firstEvents = try await first.start(command: "IFS= read -r line", columns: 80, rows: 24)
        let secondEvents = try await second.start(
            command: "IFS= read -r line; printf 'SURVIVED:%s\\n' \"$line\"",
            columns: 80,
            rows: 24
        )
        await first.close()
        await first.close()
        _ = await collect(firstEvents)
        try await second.write(Data("ok\n".utf8))
        let result = await collect(secondEvents)
        await second.close()
        #expect(result.status == 0)
        #expect(result.text.contains("SURVIVED:ok"))
        #expect(result.failures.isEmpty)
    }

    @Test("Invalid sizes and oversized commands fail before a child is created")
    func invalidRequests() async {
        let process = MobilePTYProcess(environment: environment)
        await #expect(throws: MobilePTYProcessError.invalidRequest) {
            _ = try await process.start(command: "exit 0", columns: 0, rows: 24)
        }
        await #expect(throws: MobilePTYProcessError.invalidRequest) {
            _ = try await process.start(command: "exit 0\0", columns: 80, rows: 24)
        }
        await #expect(throws: MobilePTYProcessError.invalidRequest) {
            _ = try await process.start(command: String(repeating: "x", count: 64 * 1024), columns: 80, rows: 24)
        }
        await process.close()
        await #expect(throws: MobilePTYProcessError.notRunning) {
            _ = try await process.start(command: "exit 0", columns: 80, rows: 24)
        }
    }

    private func collect(_ stream: AsyncStream<MobilePTYOutput>) async -> (
        bytes: Data, text: String, status: Int32?, failures: [MobilePTYProcessError], largestChunk: Int
    ) {
        var bytes = Data()
        var status: Int32?
        var failures: [MobilePTYProcessError] = []
        var largestChunk = 0
        for await event in stream {
            switch event {
            case .bytes(let data): bytes.append(data); largestChunk = max(largestChunk, data.count)
            case .exited(let code): status = code
            case .failed(let error): failures.append(error)
            case .geometry: Issue.record("Raw PTY processes must not decode tmux metadata")
            }
        }
        return (bytes, String(decoding: bytes, as: UTF8.self), status, failures, largestChunk)
    }
}
