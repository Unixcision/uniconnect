import Darwin
import Foundation
import UniConnectClaudeUpdate

/// Durable, bundle-isolated recovery storage armed before any Claude session exits.
actor UniConnectClaudeUpdateJournal: ClaudeUpdateJournaling {
    private struct Document: Codable {
        let version: Int
        var records: [ClaudeUpdateRecoveryRecord]
    }

    private enum JournalError: Error {
        case invalidDirectory
        case invalidFile
        case oversizedFile
        case unsupportedVersion
        case duplicateRecord
        case tooManyRecords
        case io
    }

    private static let documentVersion = 1
    private static let maximumBytes = 4 * 1_024 * 1_024
    private static let maximumRecords = 1_024

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileURL: URL = UniConnectClaudeUpdatePaths.recoveryJournal(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func save(_ record: ClaudeUpdateRecoveryRecord) async throws {
        try withFileLock(LOCK_EX) {
            var document = try loadDocument()
            if let index = document.records.firstIndex(where: { $0.id == record.id }) {
                document.records[index] = record
            } else {
                guard document.records.count < Self.maximumRecords else {
                    throw JournalError.tooManyRecords
                }
                document.records.append(record)
            }
            document.records.sort(by: Self.recordOrder)
            try persist(document)
        }
    }

    func remove(operationID: UUID, targetID: ClaudeUpdateTargetID) async throws {
        try withFileLock(LOCK_EX) {
            var document = try loadDocument()
            document.records.removeAll {
                $0.operationID == operationID && $0.target.id == targetID
            }
            try persist(document)
        }
    }

    func pendingRecords() async throws -> [ClaudeUpdateRecoveryRecord] {
        try withFileLock(LOCK_SH) {
            try loadDocument().records.sorted(by: Self.recordOrder)
        }
    }

    private static func recordOrder(
        _ lhs: ClaudeUpdateRecoveryRecord,
        _ rhs: ClaudeUpdateRecoveryRecord
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private func loadDocument() throws -> Document {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return Document(version: Self.documentVersion, records: [])
        }
        let data = try secureRead()
        let document: Document
        do {
            document = try decoder.decode(Document.self, from: data)
        } catch {
            throw JournalError.invalidFile
        }
        guard document.version == Self.documentVersion else {
            throw JournalError.unsupportedVersion
        }
        guard document.records.count <= Self.maximumRecords else {
            throw JournalError.tooManyRecords
        }
        var identifiers = Set<String>()
        guard document.records.allSatisfy({ identifiers.insert($0.id).inserted }) else {
            throw JournalError.duplicateRecord
        }
        return document
    }

    private func persist(_ document: Document) throws {
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw JournalError.invalidFile
        }
        guard data.count <= Self.maximumBytes else { throw JournalError.oversizedFile }
        try prepareDirectory()

        let directoryPath = fileURL.deletingLastPathComponent().path
        let temporaryPath = directoryPath + "/.recovery-" + UUID().uuidString.lowercased() + ".tmp"
        let descriptor = open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw JournalError.io }

        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary { unlink(temporaryPath) }
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
                guard count > 0 else { throw JournalError.io }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw JournalError.io
        }
        guard rename(temporaryPath, fileURL.path) == 0 else { throw JournalError.io }
        shouldRemoveTemporary = false

        let directoryDescriptor = open(directoryPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw JournalError.io }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw JournalError.io }
    }

    private func withFileLock<Result>(
        _ operation: Int32,
        body: () throws -> Result
    ) throws -> Result {
        try prepareDirectory()
        let lockPath = fileURL.path + ".lock"
        let descriptor = open(
            lockPath,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw JournalError.io }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              (info.st_mode & (S_IRWXG | S_IRWXO)) == 0,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw JournalError.invalidFile
        }

        while flock(descriptor, operation) != 0 {
            guard errno == EINTR else { throw JournalError.io }
        }
        defer {
            while flock(descriptor, LOCK_UN) != 0, errno == EINTR {}
        }
        return try body()
    }

    private func secureRead() throws -> Data {
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw JournalError.io }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & (S_IRWXG | S_IRWXO)) == 0 else {
            throw JournalError.invalidFile
        }
        guard info.st_size >= 0, info.st_size <= Self.maximumBytes else {
            throw JournalError.oversizedFile
        }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw JournalError.io }
            if count == 0 { break }
            guard data.count + count <= Self.maximumBytes else {
                throw JournalError.oversizedFile
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func prepareDirectory() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        } catch {
            throw JournalError.io
        }

        var info = stat()
        guard lstat(directoryURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & (S_IRWXG | S_IRWXO)) == 0 else {
            throw JournalError.invalidDirectory
        }
    }
}
