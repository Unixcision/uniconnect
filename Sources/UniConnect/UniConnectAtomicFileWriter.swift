import Darwin
import Foundation

/// Writes a file durably without ever exposing a partially-written destination.
enum UniConnectAtomicFileWriter {
    enum DirectoryError: Error {
        case invalidPath
        case anchorOpenFailed(Int32)
        case createFailed(Int32)
        case openFailed(Int32)
        case metadataFailed(Int32)
        case notDirectory
        case unexpectedOwner
        case insecurePermissions(mode_t)
        case permissionsFailed(Int32)
        case syncFailed(Int32)
    }

    enum WriteError: Error {
        case invalidDirectory
        case openFailed(Int32)
        case permissionsFailed(Int32)
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
        case permissionsFailed(Int32)
        case syncFailed(Int32)
        case fileTooLarge
        case readFailed(Int32)
    }

    /// Reads private state through a no-follow descriptor and rejects files that
    /// are not regular, user-owned, or private before consuming any bytes.
    static func readPrivateFile(
        at source: URL,
        maximumBytes: Int = 64 * 1_024 * 1_024,
        repairPermissions: Bool = false,
        requirePrivateDirectory: Bool = true
    ) throws -> Data {
        let standardizedSource = source.standardizedFileURL
        guard maximumBytes >= 0,
              standardizedSource.isFileURL,
              isSafeImmediateChildName(standardizedSource.lastPathComponent) else {
            throw ReadError.openFailed(EINVAL)
        }
        let directoryDescriptor = try openPrivateDirectory(
            at: standardizedSource.deletingLastPathComponent(),
            permissions: 0o700,
            createIfMissing: false,
            repairPermissions: repairPermissions,
            enforceFinalPrivacy: requirePrivateDirectory,
            fileManager: .default
        )
        defer { _ = close(directoryDescriptor) }
        let descriptor = standardizedSource.lastPathComponent.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
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
        let permissions = metadata.st_mode & 0o7777
        if permissions != 0o600 {
            guard repairPermissions else {
                throw ReadError.insecurePermissions(permissions)
            }
            guard fchmod(descriptor, 0o600) == 0 else {
                throw ReadError.permissionsFailed(errno)
            }
            guard fsync(descriptor) == 0 else {
                throw ReadError.syncFailed(errno)
            }
        }
        guard metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(maximumBytes) else {
            throw ReadError.fileTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                let errorCode = errno
                if errorCode == EINTR { continue }
                throw ReadError.readFailed(errorCode)
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
        let standardizedDestination = destination.standardizedFileURL
        let directory = standardizedDestination.deletingLastPathComponent()
        let destinationName = standardizedDestination.lastPathComponent
        guard filePermissions == 0o600,
              directoryPermissions == 0o700,
              directory.isFileURL,
              standardizedDestination.isFileURL,
              isSafeImmediateChildName(destinationName) else {
            throw WriteError.invalidDirectory
        }

        let directoryDescriptor = try openPrivateDirectory(
            at: directory,
            permissions: directoryPermissions,
            createIfMissing: true,
            repairPermissions: true,
            enforceFinalPrivacy: true,
            fileManager: fileManager
        )
        defer { _ = close(directoryDescriptor) }

        let temporaryName = ".\(destinationName).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                filePermissions
            )
        }
        guard descriptor >= 0 else {
            throw WriteError.openFailed(errno)
        }

        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary {
                _ = temporaryName.withCString { unlinkat(directoryDescriptor, $0, 0) }
            }
        }

        guard fchmod(descriptor, filePermissions) == 0 else {
            throw WriteError.permissionsFailed(errno)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, cursor, remaining)
                if count < 0 {
                    let errorCode = errno
                    if errorCode == EINTR { continue }
                    throw WriteError.writeFailed(errorCode)
                }
                guard count > 0 else {
                    throw WriteError.writeFailed(EIO)
                }
                remaining -= count
                cursor = cursor.advanced(by: count)
            }
        }

        guard fsync(descriptor) == 0 else {
            throw WriteError.syncFailed(errno)
        }

        let renameResult = temporaryName.withCString { temporaryPointer in
            destinationName.withCString { destinationPointer in
                renameat(
                    directoryDescriptor,
                    temporaryPointer,
                    directoryDescriptor,
                    destinationPointer
                )
            }
        }
        guard renameResult == 0 else {
            throw WriteError.renameFailed(errno)
        }
        shouldRemoveTemporary = false
        guard fsync(directoryDescriptor) == 0 else {
            throw WriteError.directorySyncFailed(errno)
        }
    }

    /// Removes one known state file and durably records its absence in the parent directory.
    static func removeIfPresent(
        at destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let standardizedDestination = destination.standardizedFileURL
        let destinationName = standardizedDestination.lastPathComponent
        guard standardizedDestination.isFileURL,
              isSafeImmediateChildName(destinationName) else {
            throw WriteError.invalidDirectory
        }
        let directoryDescriptor = try openPrivateDirectory(
            at: standardizedDestination.deletingLastPathComponent(),
            permissions: 0o700,
            createIfMissing: false,
            repairPermissions: true,
            enforceFinalPrivacy: true,
            fileManager: fileManager
        )
        defer { _ = close(directoryDescriptor) }
        let unlinkResult = destinationName.withCString {
            unlinkat(directoryDescriptor, $0, 0)
        }
        if unlinkResult != 0 {
            let errorCode = errno
            guard errorCode == ENOENT else {
                throw WriteError.removeFailed(errorCode)
            }
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw WriteError.directorySyncFailed(errno)
        }
    }

    /// Creates or repairs one private directory without following symlinks below
    /// a trusted per-user anchor or while walking a custom absolute location.
    static func ensurePrivateDirectory(
        at directory: URL,
        permissions: mode_t = 0o700,
        fileManager: FileManager = .default
    ) throws {
        let descriptor = try openPrivateDirectory(
            at: directory,
            permissions: permissions,
            createIfMissing: true,
            repairPermissions: true,
            enforceFinalPrivacy: true,
            fileManager: fileManager
        )
        _ = close(descriptor)
    }

    /// Verifies an existing private directory through a no-follow descriptor.
    static func verifyPrivateDirectory(
        at directory: URL,
        permissions: mode_t = 0o700,
        repairPermissions: Bool = true,
        fileManager: FileManager = .default
    ) throws {
        let descriptor = try openPrivateDirectory(
            at: directory,
            permissions: permissions,
            createIfMissing: false,
            repairPermissions: repairPermissions,
            enforceFinalPrivacy: true,
            fileManager: fileManager
        )
        _ = close(descriptor)
    }

    /// Makes the current directory-entry set durable before orphan decisions are made.
    static func synchronizePrivateDirectory(
        at directory: URL,
        fileManager: FileManager = .default
    ) throws {
        let descriptor = try openPrivateDirectory(
            at: directory,
            permissions: 0o700,
            createIfMissing: false,
            repairPermissions: true,
            enforceFinalPrivacy: true,
            fileManager: fileManager
        )
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw WriteError.directorySyncFailed(errno)
        }
    }

    private static func openPrivateDirectory(
        at directory: URL,
        permissions: mode_t,
        createIfMissing: Bool,
        repairPermissions: Bool,
        enforceFinalPrivacy: Bool,
        fileManager: FileManager
    ) throws -> Int32 {
        let standardizedDirectory = directory.standardizedFileURL
        guard permissions == 0o700,
              standardizedDirectory.isFileURL,
              let route = trustedDirectoryRoute(
                  to: standardizedDirectory,
                  fileManager: fileManager
              ) else {
            throw DirectoryError.invalidPath
        }

        var descriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw DirectoryError.anchorOpenFailed(errno)
        }

        do {
            try validateDirectoryDescriptor(
                descriptor,
                requireCurrentOwner: false
            )
            for (index, component) in route.components.enumerated() {
                var didCreate = false
                if createIfMissing {
                    let createResult = component.withCString {
                        mkdirat(descriptor, $0, permissions)
                    }
                    if createResult != 0 {
                        let errorCode = errno
                        guard errorCode == EEXIST else {
                            throw DirectoryError.createFailed(errorCode)
                        }
                    }
                    didCreate = createResult == 0
                    if didCreate, fsync(descriptor) != 0 {
                        throw DirectoryError.syncFailed(errno)
                    }
                }

                let childDescriptor = component.withCString {
                    openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard childDescriptor >= 0 else {
                    throw DirectoryError.openFailed(errno)
                }
                _ = close(descriptor)
                descriptor = childDescriptor
                try validateDirectoryDescriptor(
                    descriptor,
                    requireCurrentOwner: index >= route.ownerRequiredFromIndex
                )
                if didCreate {
                    guard fchmod(descriptor, permissions) == 0 else {
                        throw DirectoryError.permissionsFailed(errno)
                    }
                    guard fsync(descriptor) == 0 else {
                        throw DirectoryError.syncFailed(errno)
                    }
                }
            }

            if enforceFinalPrivacy,
               !route.targetIsTrustedAnchor,
               !route.components.isEmpty {
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0 else {
                    throw DirectoryError.metadataFailed(errno)
                }
                let currentPermissions = metadata.st_mode & 0o7777
                if currentPermissions != permissions {
                    guard repairPermissions else {
                        throw DirectoryError.insecurePermissions(currentPermissions)
                    }
                    guard fchmod(descriptor, permissions) == 0 else {
                        throw DirectoryError.permissionsFailed(errno)
                    }
                    guard fsync(descriptor) == 0 else {
                        throw DirectoryError.syncFailed(errno)
                    }
                }
            }
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private static func validateDirectoryDescriptor(
        _ descriptor: Int32,
        requireCurrentOwner: Bool
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw DirectoryError.metadataFailed(errno)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DirectoryError.notDirectory
        }
        guard !requireCurrentOwner || metadata.st_uid == geteuid() else {
            throw DirectoryError.unexpectedOwner
        }
    }

    private static func trustedDirectoryRoute(
        to directory: URL,
        fileManager: FileManager
    ) -> (
        components: [String],
        ownerRequiredFromIndex: Int,
        targetIsTrustedAnchor: Bool
    )? {
        let candidates = [
            fileManager.homeDirectoryForCurrentUser.standardizedFileURL,
            fileManager.temporaryDirectory.standardizedFileURL,
        ].sorted { $0.path.count > $1.path.count }

        for anchor in candidates {
            guard isSameOrDescendant(directory, of: anchor) else { continue }
            let anchorComponents = anchor.pathComponents
            let directoryComponents = directory.pathComponents
            let relativeComponents = Array(directoryComponents.dropFirst(anchorComponents.count))
            guard relativeComponents.allSatisfy({ isSafeImmediateChildName($0) }) else {
                return nil
            }
            guard let resolvedAnchor = canonicalTrustedAnchor(anchor) else {
                return nil
            }
            let resolvedDirectory = relativeComponents.reduce(resolvedAnchor) { partial, component in
                partial.appendingPathComponent(component, isDirectory: true)
            }
            let components = Array(resolvedDirectory.pathComponents.dropFirst())
            let anchorComponentCount = resolvedAnchor.pathComponents.dropFirst().count
            guard anchorComponentCount > 0,
                  components.count >= anchorComponentCount,
                  components.allSatisfy({ isSafeImmediateChildName($0) }) else {
                return nil
            }
            return (
                components,
                anchorComponentCount - 1,
                relativeComponents.isEmpty
            )
        }

        // Custom locations (for example an external backup volume) are walked
        // descriptor-relative from the filesystem root. This deliberately
        // rejects any symlink in the path instead of resolving it first.
        let components = Array(directory.pathComponents.dropFirst())
        guard !components.isEmpty,
              components.allSatisfy({ isSafeImmediateChildName($0) }) else {
            return nil
        }
        return (components, components.index(before: components.endIndex), false)
    }

    /// Resolves only a FileManager-provided anchor before descriptor-relative walking begins.
    ///
    /// Foundation leaves macOS's `/var` compatibility symlink unresolved on some releases,
    /// which makes the subsequent `O_NOFOLLOW` walk fail with `ENOTDIR`. The anchor itself is
    /// trusted; every user-controlled component below it is still opened with `O_NOFOLLOW`.
    private static func canonicalTrustedAnchor(_ anchor: URL) -> URL? {
        guard anchor.isFileURL else { return nil }
        return anchor.path.withCString { path in
            guard let resolvedPath = realpath(path, nil) else { return nil }
            defer { free(resolvedPath) }
            return URL(
                fileURLWithPath: String(cString: resolvedPath),
                isDirectory: true
            )
        }
    }

    private static func isSameOrDescendant(_ candidate: URL, of anchor: URL) -> Bool {
        let anchorComponents = anchor.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= anchorComponents.count else { return false }
        return Array(candidateComponents.prefix(anchorComponents.count)) == anchorComponents
    }

    private static func isSafeImmediateChildName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.utf8.contains(0)
    }
}
