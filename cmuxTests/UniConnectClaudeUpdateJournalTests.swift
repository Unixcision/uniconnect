import Foundation
import Testing
import UniConnectClaudeUpdate

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect Claude update recovery journal")
struct UniConnectClaudeUpdateJournalTests {
    @Test("Saves, replaces, orders, and removes durable recovery obligations")
    func recoveryLifecycle() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("recovery.json")
        let journal = UniConnectClaudeUpdateJournal(fileURL: file)
        let first = record(
            operationID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            targetID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            stage: .exitRequested,
            date: Date(timeIntervalSince1970: 20)
        )
        let second = record(
            operationID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            targetID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            stage: .exitRequested,
            date: Date(timeIntervalSince1970: 10)
        )

        try await journal.save(first)
        try await journal.save(second)
        var pending = try await journal.pendingRecords()
        #expect(pending.map(\.id) == [second.id, first.id])

        let replaced = record(
            operationID: first.operationID,
            targetID: UUID(uuidString: first.target.id.rawValue)!,
            stage: .shellReady,
            date: Date(timeIntervalSince1970: 30)
        )
        try await journal.save(replaced)
        pending = try await journal.pendingRecords()
        #expect(pending.count == 2)
        #expect(pending.first(where: { $0.id == first.id })?.stage == .shellReady)

        try await journal.remove(operationID: second.operationID, targetID: second.target.id)
        pending = try await journal.pendingRecords()
        #expect(pending.map(\.id) == [first.id])

        let fileMode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        let lockMode = try #require(try FileManager.default.attributesOfItem(atPath: file.path + ".lock")[.posixPermissions] as? Int)
        let directoryMode = try #require(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int)
        #expect(fileMode == 0o600)
        #expect(lockMode == 0o600)
        #expect(directoryMode == 0o700)
    }

    @Test("Concurrent journal instances preserve every recovery obligation")
    func concurrentWritersPreserveAllRecords() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("recovery.json")
        let firstJournal = UniConnectClaudeUpdateJournal(fileURL: file)
        let secondJournal = UniConnectClaudeUpdateJournal(fileURL: file)
        let records = (0..<96).map { index in
            record(
                operationID: UUID(),
                targetID: UUID(),
                stage: index.isMultiple(of: 2) ? .exitRequested : .shellReady,
                date: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, record) in records.enumerated() {
                let journal = index.isMultiple(of: 2) ? firstJournal : secondJournal
                group.addTask {
                    try await journal.save(record)
                }
            }
            try await group.waitForAll()
        }

        let pending = try await firstJournal.pendingRecords()
        #expect(pending.count == records.count)
        #expect(Set(pending.map(\.id)) == Set(records.map(\.id)))
    }

    @Test("Honors an exclusive journal lock held by a separate process")
    func honorsSeparateProcessLock() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("recovery.json")
        let journal = UniConnectClaudeUpdateJournal(fileURL: file)
        _ = try await journal.pendingRecords()

        let child = Process()
        let childInput = Pipe()
        let childOutput = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            """
            import fcntl, os, sys
            descriptor = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            sys.stdout.buffer.write(b"locked\\n")
            sys.stdout.buffer.flush()
            sys.stdin.buffer.read(1)
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
            """,
            file.path + ".lock",
        ]
        child.standardInput = childInput
        child.standardOutput = childOutput
        try child.run()
        defer {
            try? childInput.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
        }

        let readyData = try #require(
            try childOutput.fileHandleForReading.read(upToCount: 7)
        )
        #expect(String(decoding: readyData, as: UTF8.self) == "locked\n")

        let entry = record(
            operationID: UUID(),
            targetID: UUID(),
            stage: .exitRequested,
            date: Date(timeIntervalSince1970: 1)
        )
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let saveTask = Task {
            started.continuation.yield()
            try await journal.save(entry)
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: file.path))

        try childInput.fileHandleForWriting.write(contentsOf: Data([0x78]))
        try childInput.fileHandleForWriting.close()
        try await saveTask.value
        child.waitUntilExit()

        #expect(child.terminationStatus == 0)
        #expect(try await journal.pendingRecords().map(\.id) == [entry.id])
    }

    @Test("Rejects a symlink instead of following it")
    func rejectsSymlink() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data(#"{"version":1,"records":[]}"#.utf8).write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
        let file = root.appendingPathComponent("recovery.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        let journal = UniConnectClaudeUpdateJournal(fileURL: file)

        await #expect(throws: (any Error).self) {
            try await journal.pendingRecords()
        }
    }

    @Test("Rejects a symlinked interprocess lock")
    func rejectsSymlinkedLock() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data().write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
        let file = root.appendingPathComponent("recovery.json")
        try FileManager.default.createSymbolicLink(
            atPath: file.path + ".lock",
            withDestinationPath: outside.path
        )
        let journal = UniConnectClaudeUpdateJournal(fileURL: file)

        await #expect(throws: (any Error).self) {
            try await journal.pendingRecords()
        }
    }

    @Test("Keeps tagged builds out of the release recovery directory")
    func pathsAreBundleIsolated() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let release = UniConnectClaudeUpdatePaths.recoveryJournal(
            homeDirectory: home,
            bundleIdentifier: UniConnectIdentity.releaseBundleIdentifier
        )
        let tagged = UniConnectClaudeUpdatePaths.recoveryJournal(
            homeDirectory: home,
            bundleIdentifier: "com.unixcision.uniconnect.debug.flyout"
        )

        #expect(release.path == "/Users/tester/.uniconnect/claude-update/recovery.json")
        #expect(tagged.path.contains("/claude-update/development/com.unixcision.uniconnect.debug.flyout/"))
        #expect(release != tagged)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-update-journal-\(UUID().uuidString)", isDirectory: true)
    }

    private func record(
        operationID: UUID,
        targetID: UUID,
        stage: ClaudeRecoveryStage,
        date: Date
    ) -> ClaudeUpdateRecoveryRecord {
        let binding = ClaudeSessionBinding(
            sessionID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            workingDirectory: "/tmp/project",
            executablePath: "/opt/claude/bin/claude",
            installationID: "installation"
        )
        let target = ClaudeUpdateTarget(
            id: ClaudeUpdateTargetID(rawValue: targetID.uuidString.lowercased()),
            boxID: "box",
            displayName: "window",
            host: ClaudeUpdateHostIdentity(kind: .local, id: "local", displayName: "Local"),
            binding: binding,
            pane: nil
        )
        return ClaudeUpdateRecoveryRecord(
            operationID: operationID,
            target: target,
            stage: stage,
            observedProcessID: 42,
            versionBefore: ClaudeVersion(major: 1, minor: 0, patch: 0),
            updatedAt: date
        )
    }
}
