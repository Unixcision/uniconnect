import Darwin
import Foundation

/// Writes a file durably without ever exposing a partially-written destination.
enum UniConnectAtomicFileWriter {
    enum WriteError: Error {
        case invalidDirectory
        case openFailed(Int32)
        case writeFailed(Int32)
        case syncFailed(Int32)
        case renameFailed(Int32)
        case removeFailed(Int32)
        case directoryOpenFailed(Int32)
        case directorySyncFailed(Int32)

        /// The final destination is already visible after rename for these failures.
        var destinationWasCommitted: Bool {
            switch self {
            case .directoryOpenFailed, .directorySyncFailed:
                return true
            default:
                return false
            }
        }
    }

    enum ReadError: Error {
        case openFailed(Int32)
        case metadataFailed(Int32)
        case notRegularFile
        case unexpectedOwner
        case insecurePermissions(mode_t)
        case fileTooLarge
        case readFailed(Int32)
    }

    /// Reads private state through a no-follow descriptor and rejects files that
    /// are not regular, user-owned, or private before consuming any bytes.
    static func readPrivateFile(
        at source: URL,
        maximumBytes: Int = 64 * 1_024 * 1_024,
        repairPermissions: Bool = false
    ) throws -> Data {
        let descriptor = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ReadError.openFailed(errno)
        }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw ReadError.metadataFailed(errno)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ReadError.notRegularFile
        }
        guard metadata.st_uid == geteuid() else {
            throw ReadError.unexpectedOwner
        }
        let permissions = metadata.st_mode & 0o777
        if permissions & 0o177 != 0 {
            guard repairPermissions, fchmod(descriptor, 0o600) == 0 else {
                throw ReadError.insecurePermissions(permissions)
            }
        }
        guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
            throw ReadError.fileTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw ReadError.readFailed(errno)
            }
            guard count > 0 else { break }
            guard data.count <= maximumBytes - count else {
                throw ReadError.fileTooLarge
            }
            data.append(buffer, count: count)
        }
        return data
    }

    static func write(
        _ data: Data,
        to destination: URL,
        filePermissions: mode_t = 0o600,
        directoryPermissions: mode_t = 0o700,
        fileManager: FileManager = .default
    ) throws {
        let directory = destination.deletingLastPathComponent()
        guard directory.isFileURL, destination.isFileURL else {
            throw WriteError.invalidDirectory
        }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: directoryPermissions)]
        )
        _ = chmod(directory.path, directoryPermissions)

        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            filePermissions
        )
        guard descriptor >= 0 else {
            throw WriteError.openFailed(errno)
        }

        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary {
                try? fileManager.removeItem(at: temporary)
            }
        }

        _ = fchmod(descriptor, filePermissions)
        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, cursor, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw WriteError.writeFailed(errno)
                }
                remaining -= count
                cursor = cursor.advanced(by: count)
            }
        }

        guard fsync(descriptor) == 0 else {
            throw WriteError.syncFailed(errno)
        }

        guard rename(temporary.path, destination.path) == 0 else {
            throw WriteError.renameFailed(errno)
        }
        shouldRemoveTemporary = false
        _ = chmod(destination.path, filePermissions)

        try synchronizeDirectory(directory)
    }

    /// Removes one known state file and durably records its absence in the parent directory.
    static func removeIfPresent(at destination: URL) throws {
        guard destination.isFileURL else { throw WriteError.invalidDirectory }
        if unlink(destination.path) != 0, errno != ENOENT {
            throw WriteError.removeFailed(errno)
        }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw WriteError.directoryOpenFailed(errno)
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw WriteError.directorySyncFailed(errno)
        }
    }
}
