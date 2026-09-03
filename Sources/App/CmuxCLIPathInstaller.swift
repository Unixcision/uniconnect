import Foundation

struct CmuxCLIPathInstaller {
    struct InstallOutcome {
        let usedAdministratorPrivileges: Bool
        let destinationURL: URL
        let sourceURL: URL
    }

    struct UninstallOutcome {
        let usedAdministratorPrivileges: Bool
        let destinationURL: URL
        let removedExistingEntry: Bool
    }

    enum InstallerError: LocalizedError {
        case bundledCLIMissing(expectedPath: String)
        case destinationParentNotDirectory(path: String)
        case destinationIsDirectory(path: String)
        case destinationBelongsToAnotherTool(path: String)
        case destinationIsNotOwned(path: String)
        case installVerificationFailed(path: String)
        case uninstallVerificationFailed(path: String)
        case privilegedCommandFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .bundledCLIMissing(let expectedPath):
                return String(
                    localized: "cli.path.error.bundledMissing",
                    defaultValue: "Bundled cmux CLI was not found at \(expectedPath)."
                )
            case .destinationParentNotDirectory(let path):
                return String(
                    localized: "cli.path.error.parentNotDirectory",
                    defaultValue: "Expected \(path) to be a directory."
                )
            case .destinationIsDirectory(let path):
                return String(
                    localized: "cli.path.error.destinationIsDirectory",
                    defaultValue: "\(path) is a directory. Remove or rename it and try again."
                )
            case .destinationBelongsToAnotherTool(let path):
                return String(
                    localized: "cli.path.error.destinationOccupied",
                    defaultValue: "UniConnect will not replace \(path) because it belongs to another installation or tool."
                )
            case .destinationIsNotOwned(let path):
                return String(
                    localized: "cli.path.error.destinationNotOwned",
                    defaultValue: "UniConnect will not remove \(path) because it does not point to this app's bundled cmux CLI."
                )
            case .installVerificationFailed(let path):
                return String(
                    localized: "cli.path.error.installVerification",
                    defaultValue: "Installed symlink at \(path) did not point to the bundled cmux CLI."
                )
            case .uninstallVerificationFailed(let path):
                return String(
                    localized: "cli.path.error.uninstallVerification",
                    defaultValue: "Failed to remove \(path)."
                )
            case .privilegedCommandFailed(let message):
                return String(
                    localized: "cli.path.error.privilegedCommand",
                    defaultValue: "Administrator action failed: \(message)"
                )
            }
        }
    }

    typealias PrivilegedInstallHandler = (_ sourceURL: URL, _ destinationURL: URL) throws -> Void
    typealias PrivilegedUninstallHandler = (_ sourceURL: URL, _ destinationURL: URL) throws -> Void

    let fileManager: FileManager
    let destinationURL: URL
    private let bundledCLIURLProvider: () -> URL?
    private let expectedBundledCLIPath: String
    private let privilegedInstaller: PrivilegedInstallHandler
    private let privilegedUninstaller: PrivilegedUninstallHandler

    init(
        fileManager: FileManager = .default,
        destinationURL: URL = URL(fileURLWithPath: "/usr/local/bin/cmux"),
        bundledCLIURLProvider: @escaping () -> URL? = {
            CmuxCLIPathInstaller.defaultBundledCLIURL()
        },
        expectedBundledCLIPath: String = CmuxCLIPathInstaller.defaultBundledCLIExpectedPath(),
        privilegedInstaller: PrivilegedInstallHandler? = nil,
        privilegedUninstaller: PrivilegedUninstallHandler? = nil
    ) {
        self.fileManager = fileManager
        self.destinationURL = destinationURL
        self.bundledCLIURLProvider = bundledCLIURLProvider
        self.expectedBundledCLIPath = expectedBundledCLIPath
        self.privilegedInstaller = privilegedInstaller ?? Self.installWithAdministratorPrivileges(sourceURL:destinationURL:)
        self.privilegedUninstaller = privilegedUninstaller ?? Self.uninstallWithAdministratorPrivileges(sourceURL:destinationURL:)
    }

    var destinationPath: String {
        destinationURL.path
    }

    func install() throws -> InstallOutcome {
        let sourceURL = try resolveBundledCLIURL()
        do {
            try installWithoutAdministratorPrivileges(sourceURL: sourceURL)
            return InstallOutcome(
                usedAdministratorPrivileges: false,
                destinationURL: destinationURL,
                sourceURL: sourceURL
            )
        } catch {
            guard Self.isPermissionDenied(error) else { throw error }
            try ensureDestinationIsNotDirectory()
            try privilegedInstaller(sourceURL, destinationURL)
            try verifyInstalledSymlinkTarget(sourceURL: sourceURL)
            return InstallOutcome(
                usedAdministratorPrivileges: true,
                destinationURL: destinationURL,
                sourceURL: sourceURL
            )
        }
    }

    func uninstall() throws -> UninstallOutcome {
        let sourceURL = try resolveBundledCLIURL()
        do {
            let removedExistingEntry = try uninstallWithoutAdministratorPrivileges(sourceURL: sourceURL)
            return UninstallOutcome(
                usedAdministratorPrivileges: false,
                destinationURL: destinationURL,
                removedExistingEntry: removedExistingEntry
            )
        } catch {
            guard Self.isPermissionDenied(error) else { throw error }
            try ensureDestinationIsNotDirectory()
            let removedExistingEntry = destinationEntryExists()
            if removedExistingEntry {
                try ensureDestinationIsOwned(by: sourceURL)
            }
            try privilegedUninstaller(sourceURL, destinationURL)
            if destinationEntryExists() {
                throw InstallerError.uninstallVerificationFailed(path: destinationURL.path)
            }
            return UninstallOutcome(
                usedAdministratorPrivileges: true,
                destinationURL: destinationURL,
                removedExistingEntry: removedExistingEntry
            )
        }
    }

    func isInstalled() -> Bool {
        guard let sourceURL = bundledCLIURLProvider()?.standardizedFileURL else { return false }
        guard let installedTargetURL = symlinkDestinationURL() else { return false }
        return installedTargetURL == sourceURL
    }

    private func resolveBundledCLIURL() throws -> URL {
        guard let sourceURL = bundledCLIURLProvider()?.standardizedFileURL else {
            throw InstallerError.bundledCLIMissing(expectedPath: expectedBundledCLIPath)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw InstallerError.bundledCLIMissing(expectedPath: sourceURL.path)
        }
        return sourceURL
    }

    private func installWithoutAdministratorPrivileges(sourceURL: URL) throws {
        try ensureDestinationParentDirectoryExists()
        try ensureDestinationIsNotDirectory()
        if destinationEntryExists() {
            try ensureDestinationIsOwned(by: sourceURL, installing: true)
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: sourceURL)
        try verifyInstalledSymlinkTarget(sourceURL: sourceURL)
    }

    @discardableResult
    private func uninstallWithoutAdministratorPrivileges(sourceURL: URL) throws -> Bool {
        try ensureDestinationIsNotDirectory()
        let existed = destinationEntryExists()
        if existed {
            try ensureDestinationIsOwned(by: sourceURL)
            try fileManager.removeItem(at: destinationURL)
        }
        if destinationEntryExists() {
            throw InstallerError.uninstallVerificationFailed(path: destinationURL.path)
        }
        return existed
    }

    /// Check if the destination path has any filesystem entry (including dangling symlinks).
    /// `FileManager.fileExists` follows symlinks, so a dangling symlink returns false.
    private func destinationEntryExists() -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: destinationURL.path)) != nil
            || fileManager.fileExists(atPath: destinationURL.path)
    }

    private func verifyInstalledSymlinkTarget(sourceURL: URL) throws {
        guard let installedTargetURL = symlinkDestinationURL(),
              installedTargetURL == sourceURL.standardizedFileURL else {
            throw InstallerError.installVerificationFailed(path: destinationURL.path)
        }
    }

    private func symlinkDestinationURL() -> URL? {
        guard let destinationPath = try? fileManager.destinationOfSymbolicLink(atPath: destinationURL.path) else {
            return nil
        }
        return URL(
            fileURLWithPath: destinationPath,
            relativeTo: destinationURL.deletingLastPathComponent()
        ).standardizedFileURL
    }

    private func ensureDestinationIsOwned(
        by sourceURL: URL,
        installing: Bool = false
    ) throws {
        guard symlinkDestinationURL() == sourceURL.standardizedFileURL else {
            if installing {
                throw InstallerError.destinationBelongsToAnotherTool(path: destinationURL.path)
            }
            throw InstallerError.destinationIsNotOwned(path: destinationURL.path)
        }
    }

    private func ensureDestinationParentDirectoryExists() throws {
        let parentURL = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw InstallerError.destinationParentNotDirectory(path: parentURL.path)
            }
            return
        }
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    }

    private func ensureDestinationIsNotDirectory() throws {
        guard let values = try resourceValuesIfFileExists(
            at: destinationURL,
            keys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return
        }

        if values.isDirectory == true, values.isSymbolicLink != true {
            throw InstallerError.destinationIsDirectory(path: destinationURL.path)
        }
    }

    private func resourceValuesIfFileExists(
        at url: URL,
        keys: Set<URLResourceKey>
    ) throws -> URLResourceValues? {
        do {
            return try url.resourceValues(forKeys: keys)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return nil
            }
            if nsError.domain == NSPOSIXErrorDomain,
               POSIXErrorCode(rawValue: Int32(nsError.code)) == .ENOENT {
                return nil
            }
            throw error
        }
    }

    private static func defaultBundledCLIURL(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent("bin/cmux", isDirectory: false)
    }

    private static func defaultBundledCLIExpectedPath(bundle: Bundle = .main) -> String {
        bundle.bundleURL
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
            .path
    }

    private static func installWithAdministratorPrivileges(sourceURL: URL, destinationURL: URL) throws {
        let destinationPath = destinationURL.path
        let parentPath = destinationURL.deletingLastPathComponent().path
        let sourcePath = sourceURL.path
        let command = "/bin/mkdir -p \(shellQuoted(parentPath)) && " +
            "if [ -e \(shellQuoted(destinationPath)) ] || [ -L \(shellQuoted(destinationPath)) ]; then " +
            "[ -L \(shellQuoted(destinationPath)) ] && " +
            "[ \"$(/usr/bin/readlink \(shellQuoted(destinationPath)))\" = \(shellQuoted(sourcePath)) ] || exit 73; " +
            "fi && /bin/rm -f \(shellQuoted(destinationPath)) && " +
            "/bin/ln -s \(shellQuoted(sourceURL.path)) \(shellQuoted(destinationPath))"
        try runPrivilegedShellCommand(command)
    }

    private static func uninstallWithAdministratorPrivileges(sourceURL: URL, destinationURL: URL) throws {
        let destinationPath = destinationURL.path
        let command = "if [ -e \(shellQuoted(destinationPath)) ] || [ -L \(shellQuoted(destinationPath)) ]; then " +
            "[ -L \(shellQuoted(destinationPath)) ] && " +
            "[ \"$(/usr/bin/readlink \(shellQuoted(destinationPath)))\" = \(shellQuoted(sourceURL.path)) ] || exit 73; " +
            "/bin/rm -f \(shellQuoted(destinationPath)); fi"
        try runPrivilegedShellCommand(command)
    }

    private static func runPrivilegedShellCommand(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            command
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutBuffer = PrivilegedCommandOutputBuffer()
        let stderrBuffer = PrivilegedCommandOutputBuffer()
        process.standardOutput = stdout
        process.standardError = stderr
        let outputGroup = DispatchGroup()
        startDraining(stdout, into: stdoutBuffer, group: outputGroup)
        startDraining(stderr, into: stderrBuffer, group: outputGroup)
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }
        try process.run()
        process.waitUntilExit()
        outputGroup.wait()

        guard process.terminationStatus == 0 else {
            let stderrText = stderrBuffer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutText = stdoutBuffer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let details = stderrText.isEmpty ? stdoutText : stderrText
            let message = details.isEmpty
                ? "osascript exited with status \(process.terminationStatus)."
                : details
            throw InstallerError.privilegedCommandFailed(message: message)
        }
    }

    private static func startDraining(
        _ pipe: Pipe,
        into buffer: PrivilegedCommandOutputBuffer,
        group: DispatchGroup
    ) {
        group.enter()
        pipe.fileHandleForReading.readabilityHandler = { fileHandle in
            switch ProcessPipeReader.readAvailableDataOrEndOfFile(from: fileHandle) {
            case .data(let data):
                buffer.append(data)
            case .wouldBlock:
                return
            case .endOfFile:
                fileHandle.readabilityHandler = nil
                group.leave()
            }
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        isPermissionDenied(error as NSError)
    }

    private static func isPermissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(error.code)),
           code == .EACCES || code == .EPERM || code == .EROFS {
            return true
        }

        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return true
            default:
                break
            }
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlying)
        }

        return false
    }
}

private final class PrivilegedCommandOutputBuffer {
    private let lock = NSLock()
    private var data = Data()

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}
