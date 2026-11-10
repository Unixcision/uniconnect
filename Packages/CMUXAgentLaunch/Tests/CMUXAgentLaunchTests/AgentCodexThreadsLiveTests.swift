import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Prueba en vivo con un Codex real: nunca corre sola, hace falta `UC_LIVE_CODEX_PANE=<pane_pid>`
/// (y `UC_LIVE_CODEX_ID` con el id que debe salir). Lee la tabla de procesos con `ps`, las carpetas
/// con `lsof` y la tabla `threads` real de `~/.codex`, en solo lectura.
@Suite("Codex en vivo por su tabla threads", .enabled(if: ProcessInfo.processInfo.environment["UC_LIVE_CODEX_PANE"] != nil))
struct AgentCodexThreadsLiveTests {
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("Un codex 0.167 lanzado a mano sale con el id de su hilo")
    func manualCodexIsIdentified() throws {
        let environment = ProcessInfo.processInfo.environment
        let pane = try #require(Int(environment["UC_LIVE_CODEX_PANE"] ?? ""))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        var table: [AgentProcessSample] = []
        for line in try run("/bin/ps", ["-Ao", "pid=,ppid=,uid=,lstart=,args="]).split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 9, let pid = Int(fields[0]), let ppid = Int(fields[1]), let uid = Int(fields[2]) else { continue }
            let start = formatter.date(from: fields[3...7].joined(separator: " "))
            table.append(AgentProcessSample(
                pid: pid, parentPID: ppid, userID: uid, arguments: Array(fields[8...]),
                startMilliseconds: start.map { Int64($0.timeIntervalSince1970 * 1000) }
            ))
        }
        let directory: (Int) -> String? = { pid in
            (try? run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]))?
                .split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        }
        let store = AgentCodexThreadStore(codexHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        let outcome = AgentProcessDiscovery().discover(
            rootPID: pane, processes: table, claudeSession: { _ in nil }, openFiles: [:],
            rolloutFirstLine: { _ in nil }, fallbackDirectory: nil, processDirectory: directory,
            resolvingPath: { (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? $0 },
            codexThreads: { store.threads(workingDirectories: $0) }
        )
        print("resultado en vivo: \(outcome)")
        guard case let .found(conversation) = outcome else {
            Issue.record("sin conversación: \(outcome)")
            return
        }
        #expect(conversation.provider == .codex)
        #expect(conversation.source == .threads)
        if let expected = environment["UC_LIVE_CODEX_ID"] { #expect(conversation.sessionID == expected) }
    }
}
