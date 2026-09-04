import Darwin
import Foundation
import UniConnectClaudeUpdate

/// Appends bounded updater state transitions using a credential-free JSON schema.
actor UniConnectClaudeUpdateLogger: ClaudeUpdateLogging {
    private struct SafeEntry: Codable {
        let timestamp: Date
        let operationID: UUID
        let level: String
        let phase: String
        let hostID: String?
        let targetID: String?
        let issue: String?

        init(_ entry: ClaudeUpdateLogEntry) {
            timestamp = entry.timestamp
            operationID = entry.operationID
            level = entry.level.rawValue
            phase = entry.phase.rawValue
            if entry.hostID == UniConnectClaudeUpdateHostID.local {
                hostID = UniConnectClaudeUpdateHostID.local
            } else if let rawHostID = entry.hostID,
                      let credentialID = UniConnectClaudeUpdateHostID.credentialID(from: rawHostID) {
                hostID = UniConnectClaudeUpdateHostID.remote(credentialID: credentialID)
            } else {
                hostID = nil
            }
            targetID = entry.targetID
                .flatMap { UUID(uuidString: $0.rawValue) }?
                .uuidString
                .lowercased()
            issue = entry.issue?.rawValue
        }
    }

    private static let maximumLogBytes: off_t = 2 * 1_024 * 1_024

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    init(
        fileURL: URL = UniConnectClaudeUpdatePaths.structuredLog(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    func record(_ entry: ClaudeUpdateLogEntry) async {
        guard let encoded = try? encoder.encode(SafeEntry(entry)) else { return }
        var line = encoded
        line.append(0x0A)
        guard line.count <= 16 * 1_024 else { return }
        try? prepareDirectory()
        try? rotateIfNeeded(appending: line.count)
        try? append(line)
    }

    private func append(_ data: Data) throws {
        let descriptor = open(
            fileURL.path,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func rotateIfNeeded(appending byteCount: Int) throws {
        var info = stat()
        if lstat(fileURL.path, &info) != 0 {
            guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & (S_IRWXG | S_IRWXO)) == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        guard info.st_size + off_t(byteCount) > Self.maximumLogBytes else { return }

        let archivedURL = fileURL.appendingPathExtension("1")
        _ = unlink(archivedURL.path)
        guard rename(fileURL.path, archivedURL.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func prepareDirectory() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        var info = stat()
        guard lstat(directoryURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & (S_IRWXG | S_IRWXO)) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
