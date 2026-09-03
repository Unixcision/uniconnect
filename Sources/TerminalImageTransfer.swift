import Foundation
import AppKit
import UniformTypeIdentifiers

enum TerminalImageTransferMode {
    case paste
    case drop
}

enum TerminalRemoteUploadTarget: Equatable {
    case workspaceRemote
    case detectedSSH(DetectedSSHSession)
}

enum TerminalImageTransferUnavailableReason: Equatable {
    case disconnectedSSHWindow
    case missingSSHConnectCommand
    case unparseableSSHConnectCommand
    case nonUploadableRemoteItems

    var localizedDescription: String {
        switch self {
        case .disconnectedSSHWindow:
            return String(
                localized: "terminal.imageTransfer.error.disconnectedSSHWindow",
                defaultValue: "This SSH window is disconnected. Reconnect it, then try attaching the file again."
            )
        case .missingSSHConnectCommand:
            return String(
                localized: "terminal.imageTransfer.error.missingSSHConnectCommand",
                defaultValue: "This SSH box doesn't have a usable saved connection command. Edit the connection, then try again."
            )
        case .unparseableSSHConnectCommand:
            return String(
                localized: "terminal.imageTransfer.error.unparseableSSHConnectCommand",
                defaultValue: "UniConnect couldn't interpret this box's SSH connection command for file transfer."
            )
        case .nonUploadableRemoteItems:
            return String(
                localized: "terminal.imageTransfer.error.nonUploadableRemoteItems",
                defaultValue: "Only regular files can be attached to a remote session. Folders and mixed selections aren't supported."
            )
        }
    }
}

enum TerminalImageTransferTarget: Equatable {
    case local
    case remote(TerminalRemoteUploadTarget)
    /// The box is SSH but nothing can be uploaded right now (no usable connect command,
    /// window disconnected). Never degrade to `.local`: pasting a Mac path into a remote
    /// shell is worse than doing nothing, so the transfer is rejected and the user told.
    case unavailable(TerminalImageTransferUnavailableReason)
}

enum TerminalImageTransferPlan: Equatable {
    case insertText(String)
    case insertTextSegments([String], interSegmentDelay: TimeInterval)
    case uploadFiles([URL], TerminalRemoteUploadTarget)
    case unavailable(TerminalImageTransferUnavailableReason)
    case reject
}

enum TerminalImageTransferPreparedContent: Equatable {
    case insertText(String)
    case fileURLs([URL])
    case reject
}

enum PasteboardFileURLReader {
    static let legacyFilenamesPboardType = NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
    static let fileURLPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL,
        legacyFilenamesPboardType
    ]

    static func hasFileURLType(_ pasteboardTypes: [NSPasteboard.PasteboardType]) -> Bool {
        return pasteboardTypes.contains { fileURLPasteboardTypes.contains($0) }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var fileURLs: [URL] = []

        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        for object in objects {
            if let url = object as? URL, url.isFileURL {
                fileURLs.append(url.standardizedFileURL)
            }
        }

        if let paths = pasteboard.propertyList(forType: legacyFilenamesPboardType) as? [String] {
            fileURLs.append(
                contentsOf: paths
                    .filter { !$0.isEmpty }
                    .map { URL(fileURLWithPath: $0).standardizedFileURL }
            )
        }

        if let rawFileURL = pasteboard.string(forType: .fileURL),
           let url = URL(string: rawFileURL),
           url.isFileURL {
            fileURLs.append(url.standardizedFileURL)
        }

        var seen: Set<String> = []
        return fileURLs.filter { url in
            seen.insert(url.path).inserted
        }
    }
}

enum TerminalImageTransferExecutionError: Error, Equatable {
    case cancelled
    case unavailable(TerminalImageTransferUnavailableReason)
    case rejectedContent
    case emptyRemoteUploadResult
}

extension TerminalImageTransferExecutionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cancelled:
            return nil
        case .unavailable(let reason):
            return reason.localizedDescription
        case .rejectedContent:
            return String(
                localized: "terminal.imageTransfer.error.rejectedContent",
                defaultValue: "The clipboard or dropped item doesn't contain text or a supported file."
            )
        case .emptyRemoteUploadResult:
            return String(
                localized: "terminal.imageTransfer.error.emptyRemoteUploadResult",
                defaultValue: "The file transfer finished without returning a remote file path."
            )
        }
    }
}

final class TerminalImageTransferOperation: @unchecked Sendable {
    private enum State {
        case running
        case cancelled
        case finished
    }

    private let lock = NSLock()
    private var state: State = .running
    private var cancellationHandler: (() -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .cancelled
    }

    func installCancellationHandler(_ handler: @escaping () -> Void) {
        var invokeImmediately = false
        lock.lock()
        switch state {
        case .running:
            cancellationHandler = handler
        case .cancelled:
            invokeImmediately = true
        case .finished:
            break
        }
        lock.unlock()

        if invokeImmediately {
            handler()
        }
    }

    func clearCancellationHandler() {
        lock.lock()
        if state == .running {
            cancellationHandler = nil
        }
        lock.unlock()
    }

    @discardableResult
    func cancel() -> Bool {
        let handler: (() -> Void)?
        lock.lock()
        guard state == .running else {
            lock.unlock()
            return false
        }
        state = .cancelled
        handler = cancellationHandler
        cancellationHandler = nil
        lock.unlock()

        handler?()
        return true
    }

    @discardableResult
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .running else { return false }
        state = .finished
        cancellationHandler = nil
        return true
    }

    func throwIfCancelled() throws {
        if isCancelled {
            throw TerminalImageTransferExecutionError.cancelled
        }
    }
}

enum TerminalImageTransferPlanner {
    static func plan(
        pasteboard: NSPasteboard,
        mode: TerminalImageTransferMode,
        target: TerminalImageTransferTarget
    ) -> TerminalImageTransferPlan {
        plan(
            preparedContent: prepare(pasteboard: pasteboard, mode: mode),
            target: target,
            mode: mode
        )
    }

    static func plan(
        pasteboard: NSPasteboard,
        mode: TerminalImageTransferMode,
        resolveTarget: () -> TerminalImageTransferTarget
    ) -> TerminalImageTransferPlan {
        let preparedContent = prepare(pasteboard: pasteboard, mode: mode)
        switch preparedContent {
        case .insertText, .reject:
            return plan(preparedContent: preparedContent, target: .local, mode: mode)
        case .fileURLs:
            return plan(preparedContent: preparedContent, target: resolveTarget(), mode: mode)
        }
    }

    static func prepare(
        pasteboard: NSPasteboard,
        mode: TerminalImageTransferMode
    ) -> TerminalImageTransferPreparedContent {
        switch mode {
        case .paste:
            return preparePaste(pasteboard: pasteboard)
        case .drop:
            return prepareDrop(pasteboard: pasteboard)
        }
    }

    static func plan(
        preparedContent: TerminalImageTransferPreparedContent,
        target: TerminalImageTransferTarget,
        mode: TerminalImageTransferMode = .paste
    ) -> TerminalImageTransferPlan {
        switch preparedContent {
        case .insertText(let text):
            return .insertText(text)
        case .fileURLs(let fileURLs):
            return plan(fileURLs: fileURLs, target: target, mode: mode)
        case .reject:
            return .reject
        }
    }

    static func plan(
        fileURLs: [URL],
        target: TerminalImageTransferTarget,
        mode: TerminalImageTransferMode = .paste
    ) -> TerminalImageTransferPlan {
        guard !fileURLs.isEmpty else { return .reject }

        switch target {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .local:
            if mode == .drop,
               fileURLs.count > 1,
               fileURLs.allSatisfy(isLocalImageFileURL) {
                return .insertTextSegments(
                    insertedTextSegments(forFileURLs: fileURLs),
                    interSegmentDelay: 2.0
                )
            }
            return .insertText(insertedText(forFileURLs: fileURLs))
        case .remote(let remoteTarget):
            guard fileURLs.allSatisfy(isRemoteUploadableFileURL) else {
                return .unavailable(.nonUploadableRemoteItems)
            }
            return .uploadFiles(fileURLs, remoteTarget)
        }
    }

    @discardableResult
    static func executeForTesting(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        uploadWorkspaceRemote: ([URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        uploadDetectedSSH: (DetectedSSHSession, [URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        insertText: @escaping (String) -> Void,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        onFailure: @escaping (Error) -> Void
    ) -> TerminalImageTransferOperation? {
        execute(
            plan: plan,
            operation: operation,
            uploadWorkspaceRemote: uploadWorkspaceRemote,
            uploadDetectedSSH: uploadDetectedSSH,
            insertText: insertText,
            scheduleAfter: scheduleAfter,
            onFailure: onFailure
        )
    }

    @discardableResult
    static func execute(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        uploadWorkspaceRemote: ([URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        uploadDetectedSSH: (DetectedSSHSession, [URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        insertText: @escaping (String) -> Void,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        onFailure: @escaping (Error) -> Void
    ) -> TerminalImageTransferOperation? {
        switch plan {
        case .insertText(let text):
            if let operation, !operation.finish() {
                return operation
            }
            insertText(text)
            return operation
        case .insertTextSegments(let segments, let interSegmentDelay):
            let operation = operation ?? TerminalImageTransferOperation()
            sendTextSegments(
                segments,
                index: 0,
                interSegmentDelay: interSegmentDelay,
                operation: operation,
                insertText: insertText,
                scheduleAfter: scheduleAfter
            )
            return operation
        case .uploadFiles(let fileURLs, .workspaceRemote):
            let operation = operation ?? TerminalImageTransferOperation()
            uploadWorkspaceRemote(fileURLs, operation) { result in
                guard operation.finish() else { return }
                finishUpload(result: result, insertText: insertText, onFailure: onFailure)
            }
            return operation
        case .uploadFiles(let fileURLs, .detectedSSH(let session)):
            let operation = operation ?? TerminalImageTransferOperation()
            uploadDetectedSSH(session, fileURLs, operation) { result in
                guard operation.finish() else { return }
                finishUpload(result: result, insertText: insertText, onFailure: onFailure)
            }
            return operation
        case .unavailable, .reject:
            return executeRejection(plan: plan, operation: operation, onFailure: onFailure)
        }
    }

    /// Completes a rejected transfer and forwards its typed, localized error to the caller.
    @discardableResult
    static func executeRejection(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        onFailure: (Error) -> Void
    ) -> TerminalImageTransferOperation? {
        let error: TerminalImageTransferExecutionError
        switch plan {
        case .unavailable(let reason):
            error = .unavailable(reason)
        case .reject:
            error = .rejectedContent
        case .insertText, .insertTextSegments, .uploadFiles:
            assertionFailure("executeRejection called with a non-rejected image transfer plan")
            return operation
        }

        if let operation, !operation.finish() {
            return operation
        }
        onFailure(error)
        return operation
    }

    static func escapeForShell(_ value: String) -> String {
        GhosttyPasteboardHelper.escapeForShell(value)
    }

    static func insertedText(forPathStrings paths: [String]) -> String {
        paths
            .map(escapeForShell)
            .joined(separator: " ")
    }

    static func insertedText(forFileURLs fileURLs: [URL]) -> String {
        insertedText(forPathStrings: fileURLs.map(\.path))
    }

    private static func insertedTextSegments(forFileURLs fileURLs: [URL]) -> [String] {
        fileURLs
            .map(\.path)
            .map(escapeForShell)
            .enumerated()
            .map { index, text in
                index == 0 ? text : " " + text
            }
    }

    private static func isLocalImageFileURL(_ fileURL: URL) -> Bool {
        let normalizedFileURL = fileURL.standardizedFileURL
        guard normalizedFileURL.isFileURL,
              let resourceValues = try? normalizedFileURL.resourceValues(forKeys: [.isRegularFileKey]),
              resourceValues.isRegularFile == true else {
            return false
        }

        let pathExtension = normalizedFileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension),
              type.conforms(to: .image) else {
            return false
        }
        return true
    }

    private static func isRemoteUploadableFileURL(_ fileURL: URL) -> Bool {
        let normalizedFileURL = fileURL.standardizedFileURL
        guard normalizedFileURL.isFileURL,
              let resourceValues = try? normalizedFileURL.resourceValues(forKeys: [.isRegularFileKey]),
              resourceValues.isRegularFile == true else {
            return false
        }
        return true
    }

    private static func preparePaste(
        pasteboard: NSPasteboard
    ) -> TerminalImageTransferPreparedContent {
        let fileURLs = fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return .fileURLs(fileURLs)
        }

        if let string = GhosttyPasteboardHelper.stringContents(from: pasteboard), !string.isEmpty {
            return .insertText(string)
        }

        switch GhosttyPasteboardHelper.materializeImageFileURLIfNeeded(from: pasteboard) {
        case .saved(let imageURL):
            return .fileURLs([imageURL])
        case .rejectedImagePayload:
            return .reject
        case .noDecodableImagePayload:
            break
        }

        // Clipboard managers can advertise unusable image types alongside valid text.
        if let string = GhosttyPasteboardHelper.fallbackPlainTextContents(from: pasteboard), !string.isEmpty {
            return .insertText(string)
        }

        if let rawURL = pasteboard.string(forType: .URL), !rawURL.isEmpty {
            return .insertText(escapeForShell(rawURL))
        }

        return .reject
    }

    private static func prepareDrop(
        pasteboard: NSPasteboard
    ) -> TerminalImageTransferPreparedContent {
        let fileURLs = materializedFileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return .fileURLs(fileURLs)
        }

        if let rawURL = pasteboard.string(forType: .URL), !rawURL.isEmpty {
            return .insertText(escapeForShell(rawURL))
        }

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return .insertText(string)
        }

        return .reject
    }

    private static func materializedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = fileURLs(from: pasteboard)
        if !urls.isEmpty {
            return urls
        }
        return GhosttyPasteboardHelper.saveImageFileURLsIfNeeded(from: pasteboard, assumeNoText: true)
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        PasteboardFileURLReader.fileURLs(from: pasteboard)
    }

    private static func finishUpload(
        result: Result<[String], Error>,
        insertText: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        switch result {
        case .success(let remotePaths):
            let content = remotePaths
                .map(escapeForShell)
                .joined(separator: " ")
            guard !content.isEmpty else {
                onFailure(TerminalImageTransferExecutionError.emptyRemoteUploadResult)
                return
            }
            insertText(content)
        case .failure(let error):
            onFailure(error)
        }
    }

    private static func sendTextSegments(
        _ segments: [String],
        index: Int,
        interSegmentDelay: TimeInterval,
        operation: TerminalImageTransferOperation,
        insertText: @escaping (String) -> Void,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void
    ) {
        guard !operation.isCancelled else { return }
        guard index < segments.count else {
            _ = operation.finish()
            return
        }

        let segment = segments[index]
        if !segment.isEmpty {
            insertText(segment)
        }

        let nextIndex = index + 1
        guard nextIndex < segments.count else {
            _ = operation.finish()
            return
        }

        scheduleAfter(interSegmentDelay) {
            sendTextSegments(
                segments,
                index: nextIndex,
                interSegmentDelay: interSegmentDelay,
                operation: operation,
                insertText: insertText,
                scheduleAfter: scheduleAfter
            )
        }
    }
}

extension TerminalSurface {
    /// Where a pasted or dropped image goes. The *kind of session* is the only source of
    /// truth: a Local box pastes locally, an SSH box uploads with its stored connect command
    /// (so it works inside tmux or a nested shell). There is no TTY or process sniffing
    /// anywhere any more; a box without a UniConnect profile is only treated as remote when
    /// cmux's own remote-workspace configuration says so.
    @MainActor
    func resolvedImageTransferTarget() -> TerminalImageTransferTarget {
        guard let workspace = owningWorkspace() else { return .local }
        switch workspace.uniConnectProfile?.kind {
        case .local:
            return .local
        case .ssh:
            if workspace.uniConnectDisconnectedPanelIds.contains(id) {
                return .unavailable(.disconnectedSSHWindow)
            }
            guard let credentialId = workspace.uniConnectProfile?.credentialId,
                  let connect = UniConnectVault.shared.connectCommand(for: credentialId) else {
                return .unavailable(.missingSSHConnectCommand)
            }
            guard let session = UniConnectSSH.detectedSession(fromConnectCommand: connect) else {
                return .unavailable(.unparseableSSHConnectCommand)
            }
            return .remote(.detectedSSH(session))
        case nil:
            return workspace.isRemoteTerminalSurface(id) ? .remote(.workspaceRemote) : .local
        }
    }
}

// MARK: - Telling the user what went wrong

/// Presents actionable transfer failures without exposing connection commands or credentials.
@MainActor
enum TerminalImageTransferErrorPresenter {
    private static func present(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "terminal.imageTransfer.error.title",
            defaultValue: "Couldn't Attach File"
        )
        alert.informativeText = message
        alert.addButton(
            withTitle: String(
                localized: "terminal.imageTransfer.error.dismiss",
                defaultValue: "OK"
            )
        )
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    static func present(_ error: Error) {
        if let transferError = error as? TerminalImageTransferExecutionError,
           transferError == .cancelled {
            return
        }
        present(error.localizedDescription)
    }
}
