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
    case detachedWindow
    case disconnectedSSHWindow
    case disconnectedRemoteSession
    case missingSSHConnectCommand
    case unparseableSSHConnectCommand
    case nonUploadableRemoteItems
    case mismatchedFileExplorerSession

    var localizedDescription: String {
        switch self {
        case .detachedWindow:
            return String(
                localized: "terminal.imageTransfer.error.detachedWindow",
                defaultValue: "This window is no longer attached to a box. Open or restore the window, then try again."
            )
        case .disconnectedSSHWindow:
            return String(
                localized: "terminal.imageTransfer.error.disconnectedSSHWindow",
                defaultValue: "This SSH window is disconnected. Reconnect it, then try attaching the file again."
            )
        case .disconnectedRemoteSession:
            return String(
                localized: "terminal.imageTransfer.error.disconnectedRemoteSession",
                defaultValue: "The remote session disconnected before the file could be attached. Reconnect it, then try again."
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
        case .mismatchedFileExplorerSession:
            return String(
                localized: "terminal.imageTransfer.error.mismatchedFileExplorerSession",
                defaultValue: "The selected File Explorer path belongs to a different session. Refresh File Explorer, then try again."
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
    case uploadFiles(
        [URL],
        TerminalRemoteUploadTarget,
        interSegmentDelay: TimeInterval?
    )
    case uploadFilesWithLeadingText(
        String,
        [URL],
        TerminalRemoteUploadTarget,
        interSegmentDelay: TimeInterval?
    )
    case unavailable(TerminalImageTransferUnavailableReason)
    case reject

    var remoteUploadTarget: TerminalRemoteUploadTarget? {
        switch self {
        case .uploadFiles(_, let target, _),
             .uploadFilesWithLeadingText(_, _, let target, _):
            return target
        case .insertText, .insertTextSegments, .unavailable, .reject:
            return nil
        }
    }

    var uploadedFileURLs: [URL]? {
        switch self {
        case .uploadFiles(let URLs, _, _),
             .uploadFilesWithLeadingText(_, let URLs, _, _):
            return URLs
        case .insertText, .insertTextSegments, .unavailable, .reject:
            return nil
        }
    }
}

enum TerminalImageTransferPreparedContent: Equatable {
    case insertText(String)
    case fileURLs([URL])
    case textAndFileURLs(String, [URL])
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
    case incompleteRemoteUploadResult
    case textDeliveryFailed
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
        case .incompleteRemoteUploadResult:
            return String(
                localized: "terminal.imageTransfer.error.incompleteRemoteUploadResult",
                defaultValue: "The file transfer didn't return a remote path for every selected file."
            )
        case .textDeliveryFailed:
            return String(
                localized: "terminal.imageTransfer.error.textDeliveryFailed",
                defaultValue: "The terminal couldn't accept the transferred file path. Try again."
            )
        }
    }
}

final class TerminalImageTransferOperation: @unchecked Sendable {
    struct ProgressSnapshot: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case preparing
            case uploading
            case finalizing
        }

        let phase: Phase
        let completedBytes: Int64
        let totalBytes: Int64

        var fractionCompleted: Double? {
            guard phase == .uploading, totalBytes > 0 else { return nil }
            return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
        }
    }

    private enum State {
        case running
        case cancelled
        case finished
    }

    private let lock = NSLock()
    private var state: State = .running
    private var cancellationHandler: (() -> Void)?
    private var cancellationCleanupHandler: (() -> Void)?
    private var progressSnapshot = ProgressSnapshot(
        phase: .preparing,
        completedBytes: 0,
        totalBytes: 0
    )
    private var progressHandler: ((ProgressSnapshot) -> Void)?
    private var progressHandlerGeneration: UInt64 = 0
    private var progressRevision: UInt64 = 0

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

    /// Starts byte-accurate upload reporting for the complete transfer batch.
    func beginUpload(totalBytes: Int64) {
        updateProgress(
            ProgressSnapshot(
                phase: .uploading,
                completedBytes: 0,
                totalBytes: max(0, totalBytes)
            )
        )
    }

    /// Reports aggregate bytes delivered to the SSH transport across all files.
    func reportUploadedBytes(_ completedBytes: Int64, totalBytes: Int64) {
        let safeTotal = max(0, totalBytes)
        updateProgress(
            ProgressSnapshot(
                phase: .uploading,
                completedBytes: min(safeTotal, max(0, completedBytes)),
                totalBytes: safeTotal
            )
        )
    }

    /// Marks the interval after all local bytes have been written while the remote
    /// transport is still acknowledging and committing the file.
    func beginFinalizing() {
        let snapshot: ProgressSnapshot
        lock.lock()
        snapshot = ProgressSnapshot(
            phase: .finalizing,
            completedBytes: progressSnapshot.completedBytes,
            totalBytes: progressSnapshot.totalBytes
        )
        lock.unlock()
        updateProgress(snapshot)
    }

    /// Installs the single presentation observer and immediately supplies current state.
    func installProgressHandler(_ handler: @escaping (ProgressSnapshot) -> Void) {
        let snapshot: ProgressSnapshot
        let generation: UInt64
        let revision: UInt64
        lock.lock()
        progressHandlerGeneration &+= 1
        progressHandler = handler
        snapshot = progressSnapshot
        generation = progressHandlerGeneration
        revision = progressRevision
        lock.unlock()
        deliverProgress(snapshot, generation: generation, revision: revision)
    }

    func clearProgressHandler() {
        lock.lock()
        progressHandlerGeneration &+= 1
        progressHandler = nil
        lock.unlock()
    }

    private func updateProgress(_ snapshot: ProgressSnapshot) {
        let generation: UInt64
        let revision: UInt64
        lock.lock()
        guard state == .running else {
            lock.unlock()
            return
        }
        progressSnapshot = snapshot
        progressRevision &+= 1
        generation = progressHandlerGeneration
        revision = progressRevision
        lock.unlock()
        deliverProgress(snapshot, generation: generation, revision: revision)
    }

    /// Drops stale callbacks when installation races a newer progress update.
    private func deliverProgress(
        _ snapshot: ProgressSnapshot,
        generation: UInt64,
        revision: UInt64
    ) {
        let handler: ((ProgressSnapshot) -> Void)?
        lock.lock()
        guard state == .running,
              progressHandlerGeneration == generation,
              progressRevision == revision else {
            lock.unlock()
            return
        }
        handler = progressHandler
        lock.unlock()
        handler?(snapshot)
    }

    /// Installs cleanup for remote files that exist but have not all been delivered yet.
    func installCancellationCleanupHandler(_ handler: @escaping () -> Void) {
        var invokeImmediately = false
        lock.lock()
        switch state {
        case .running:
            if let existingHandler = cancellationCleanupHandler {
                cancellationCleanupHandler = {
                    existingHandler()
                    handler()
                }
            } else {
                cancellationCleanupHandler = handler
            }
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

    /// Reclaims app-owned temporary source images even when cancellation happens before upload starts.
    func installTemporarySourceImageCleanup(_ fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        installCancellationCleanupHandler {
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
        }
    }

    @discardableResult
    func cancel() -> Bool {
        let handler: (() -> Void)?
        let cleanupHandler: (() -> Void)?
        lock.lock()
        guard state == .running else {
            lock.unlock()
            return false
        }
        state = .cancelled
        handler = cancellationHandler
        cleanupHandler = cancellationCleanupHandler
        cancellationHandler = nil
        cancellationCleanupHandler = nil
        progressHandlerGeneration &+= 1
        progressHandler = nil
        lock.unlock()

        handler?()
        cleanupHandler?()
        return true
    }

    @discardableResult
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .running else { return false }
        state = .finished
        cancellationHandler = nil
        cancellationCleanupHandler = nil
        progressHandlerGeneration &+= 1
        progressHandler = nil
        return true
    }

    func throwIfCancelled() throws {
        if isCancelled {
            throw TerminalImageTransferExecutionError.cancelled
        }
    }
}

enum TerminalImageTransferPlanner {
    enum PathOrigin {
        case localFileSystem([URL])
        case remoteSession(workspaceID: UUID)
    }

    private static let imageInterSegmentDelay: TimeInterval = 2.0

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
        case .fileURLs, .textAndFileURLs:
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
        case .textAndFileURLs(let text, let fileURLs):
            let filePlan = plan(fileURLs: fileURLs, target: target, mode: mode)
            switch filePlan {
            case .insertText(let paths):
                return .insertText(join(text: text, paths: paths))
            case .insertTextSegments(let segments, _):
                return .insertText(join(text: text, paths: segments.joined()))
            case .uploadFiles(let URLs, let remoteTarget, let delay):
                return .uploadFilesWithLeadingText(
                    text,
                    URLs,
                    remoteTarget,
                    interSegmentDelay: delay
                )
            case .unavailable(let reason):
                return .unavailable(reason)
            case .reject:
                return .reject
            case .uploadFilesWithLeadingText:
                preconditionFailure("nested mixed image transfer plan")
            }
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
                    interSegmentDelay: imageInterSegmentDelay
                )
            }
            return .insertText(insertedText(forFileURLs: fileURLs))
        case .remote(let remoteTarget):
            guard fileURLs.allSatisfy(isRemoteUploadableFileURL) else {
                return .unavailable(.nonUploadableRemoteItems)
            }
            let interSegmentDelay = mode == .drop
                && fileURLs.count > 1
                && fileURLs.allSatisfy(isLocalImageFileURL)
                ? imageInterSegmentDelay
                : nil
            return .uploadFiles(
                fileURLs,
                remoteTarget,
                interSegmentDelay: interSegmentDelay
            )
        }
    }

    /// Plans File Explorer insertion without confusing local Mac paths with remote paths.
    static func planPathInsertion(
        paths: [String],
        origin: PathOrigin,
        target: TerminalImageTransferTarget,
        targetWorkspaceID: UUID? = nil
    ) -> TerminalImageTransferPlan {
        guard !paths.isEmpty else { return .reject }

        if case .unavailable(let reason) = target {
            return .unavailable(reason)
        }

        switch (origin, target) {
        case (.localFileSystem, .local):
            return .insertText(insertedText(forPathStrings: paths))
        case (.localFileSystem(let fileURLs), .remote):
            return plan(fileURLs: fileURLs, target: target, mode: .paste)
        case (.remoteSession(let sourceWorkspaceID), .remote)
            where sourceWorkspaceID == targetWorkspaceID:
            return .insertText(insertedText(forPathStrings: paths))
        case (.remoteSession, .remote), (.remoteSession, .local):
            return .unavailable(.mismatchedFileExplorerSession)
        case (_, .unavailable):
            preconditionFailure("unavailable targets are handled before path-origin planning")
        }
    }

    @discardableResult
    static func executeForTesting(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        uploadWorkspaceRemote: ([URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        uploadDetectedSSH: (DetectedSSHSession, [URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        insertText: @escaping (String) -> Bool,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        isDestinationAvailable: @escaping () -> Bool = { true },
        onSuccess: @escaping () -> Void = {},
        onFailure: @escaping (Error) -> Void
    ) -> TerminalImageTransferOperation? {
        execute(
            plan: plan,
            operation: operation,
            uploadWorkspaceRemote: uploadWorkspaceRemote,
            uploadDetectedSSH: uploadDetectedSSH,
            insertText: insertText,
            scheduleAfter: scheduleAfter,
            isDestinationAvailable: isDestinationAvailable,
            onSuccess: onSuccess,
            onFailure: onFailure
        )
    }

    @discardableResult
    static func execute(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        uploadWorkspaceRemote: ([URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        uploadDetectedSSH: (DetectedSSHSession, [URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        insertText: @escaping (String) -> Bool,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        isDestinationAvailable: @escaping () -> Bool = { true },
        onSuccess: @escaping () -> Void = {},
        onFailure: @escaping (Error) -> Void
    ) -> TerminalImageTransferOperation? {
        switch plan {
        case .insertText(let text):
            if let operation, operation.isCancelled {
                return operation
            }
            guard insertText(text) else {
                if let operation {
                    if operation.cancel() {
                        onFailure(TerminalImageTransferExecutionError.textDeliveryFailed)
                    }
                } else {
                    onFailure(TerminalImageTransferExecutionError.textDeliveryFailed)
                }
                return operation
            }
            if let operation, !operation.finish() { return operation }
            onSuccess()
            return operation
        case .insertTextSegments(let segments, let interSegmentDelay):
            let operation = operation ?? TerminalImageTransferOperation()
            sendTextSegments(
                segments,
                index: 0,
                interSegmentDelay: interSegmentDelay,
                operation: operation,
                insertText: insertText,
                scheduleAfter: scheduleAfter,
                shouldContinue: isDestinationAvailable,
                onFailure: onFailure,
                onSuccess: onSuccess
            )
            return operation
        case .uploadFiles(let fileURLs, .workspaceRemote, let interSegmentDelay):
            let operation = operation ?? TerminalImageTransferOperation()
            guard !operation.isCancelled else { return operation }
            uploadWorkspaceRemote(fileURLs, operation) { result in
                finishUpload(
                    result: result,
                    sourceFileURLs: fileURLs,
                    leadingText: nil,
                    interSegmentDelay: interSegmentDelay,
                    operation: operation,
                    insertText: insertText,
                    scheduleAfter: scheduleAfter,
                    isDestinationAvailable: isDestinationAvailable,
                    onSuccess: onSuccess,
                    onFailure: onFailure
                )
            }
            return operation
        case .uploadFiles(let fileURLs, .detectedSSH(let session), let interSegmentDelay):
            let operation = operation ?? TerminalImageTransferOperation()
            guard !operation.isCancelled else { return operation }
            uploadDetectedSSH(session, fileURLs, operation) { result in
                finishUpload(
                    result: result,
                    sourceFileURLs: fileURLs,
                    leadingText: nil,
                    interSegmentDelay: interSegmentDelay,
                    operation: operation,
                    insertText: insertText,
                    scheduleAfter: scheduleAfter,
                    isDestinationAvailable: isDestinationAvailable,
                    onSuccess: onSuccess,
                    onFailure: onFailure
                )
            }
            return operation
        case .uploadFilesWithLeadingText(
            let leadingText,
            let fileURLs,
            .workspaceRemote,
            let interSegmentDelay
        ):
            let operation = operation ?? TerminalImageTransferOperation()
            guard !operation.isCancelled else { return operation }
            uploadWorkspaceRemote(fileURLs, operation) { result in
                finishUpload(
                    result: result,
                    sourceFileURLs: fileURLs,
                    leadingText: leadingText,
                    interSegmentDelay: interSegmentDelay,
                    operation: operation,
                    insertText: insertText,
                    scheduleAfter: scheduleAfter,
                    isDestinationAvailable: isDestinationAvailable,
                    onSuccess: onSuccess,
                    onFailure: onFailure
                )
            }
            return operation
        case .uploadFilesWithLeadingText(
            let leadingText,
            let fileURLs,
            .detectedSSH(let session),
            let interSegmentDelay
        ):
            let operation = operation ?? TerminalImageTransferOperation()
            guard !operation.isCancelled else { return operation }
            uploadDetectedSSH(session, fileURLs, operation) { result in
                finishUpload(
                    result: result,
                    sourceFileURLs: fileURLs,
                    leadingText: leadingText,
                    interSegmentDelay: interSegmentDelay,
                    operation: operation,
                    insertText: insertText,
                    scheduleAfter: scheduleAfter,
                    isDestinationAvailable: isDestinationAvailable,
                    onSuccess: onSuccess,
                    onFailure: onFailure
                )
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
        case .insertText, .insertTextSegments, .uploadFiles, .uploadFilesWithLeadingText:
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

    private static func join(text: String, paths: String) -> String {
        guard !text.isEmpty else { return paths }
        guard !paths.isEmpty else { return text }
        return text.last?.isWhitespace == true ? text + paths : text + " " + paths
    }

    private static func insertedTextSegments(forFileURLs fileURLs: [URL]) -> [String] {
        insertedTextSegments(forPathStrings: fileURLs.map(\.path))
    }

    private static func insertedTextSegments(forPathStrings paths: [String]) -> [String] {
        paths
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
            if case .saved(let imageURLs) = GhosttyPasteboardHelper.materializeImageFileURLsIfNeeded(
                from: pasteboard
            ), !imageURLs.isEmpty {
                return .textAndFileURLs(string, imageURLs)
            }
            return .insertText(string)
        }

        switch GhosttyPasteboardHelper.materializeImageFileURLsIfNeeded(from: pasteboard) {
        case .saved(let imageURLs):
            return .fileURLs(imageURLs)
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
        let directFileURLs = fileURLs(from: pasteboard)
        if !directFileURLs.isEmpty {
            return .fileURLs(directFileURLs)
        }

        let imageFileURLs = GhosttyPasteboardHelper.saveImageFileURLsIfNeeded(
            from: pasteboard,
            assumeNoText: true
        )
        if !imageFileURLs.isEmpty {
            if let text = GhosttyPasteboardHelper.stringContents(from: pasteboard),
               !text.isEmpty {
                return .textAndFileURLs(text, imageFileURLs)
            }
            return .fileURLs(imageFileURLs)
        }

        if let rawURL = pasteboard.string(forType: .URL), !rawURL.isEmpty {
            return .insertText(escapeForShell(rawURL))
        }

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return .insertText(string)
        }

        return .reject
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        PasteboardFileURLReader.fileURLs(from: pasteboard)
    }

    private static func finishUpload(
        result: Result<[String], Error>,
        sourceFileURLs: [URL],
        leadingText: String?,
        interSegmentDelay: TimeInterval?,
        operation: TerminalImageTransferOperation,
        insertText: @escaping (String) -> Bool,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void,
        isDestinationAvailable: @escaping () -> Bool,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        switch result {
        case .success(let remotePaths):
            guard !operation.isCancelled else { return }
            guard !remotePaths.isEmpty else {
                if operation.cancel() {
                    onFailure(TerminalImageTransferExecutionError.emptyRemoteUploadResult)
                }
                return
            }
            guard remotePaths.count == sourceFileURLs.count,
                  remotePaths.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                if operation.cancel() {
                    onFailure(TerminalImageTransferExecutionError.incompleteRemoteUploadResult)
                }
                return
            }
            guard isDestinationAvailable() else {
                if operation.cancel() {
                    onFailure(
                        TerminalImageTransferExecutionError.unavailable(.disconnectedRemoteSession)
                    )
                }
                return
            }

            if let interSegmentDelay,
               remotePaths.count > 1 {
                var segments = insertedTextSegments(forPathStrings: remotePaths)
                if let leadingText, !leadingText.isEmpty, let first = segments.first {
                    segments[0] = join(text: leadingText, paths: first)
                }
                sendTextSegments(
                    segments,
                    index: 0,
                    interSegmentDelay: interSegmentDelay,
                    operation: operation,
                    insertText: insertText,
                    scheduleAfter: scheduleAfter,
                    shouldContinue: isDestinationAvailable,
                    onFailure: onFailure,
                    onSuccess: onSuccess
                )
                return
            }

            let pathText = remotePaths.map(escapeForShell).joined(separator: " ")
            let insertion = leadingText.map { join(text: $0, paths: pathText) } ?? pathText
            guard insertText(insertion) else {
                if operation.cancel() {
                    onFailure(TerminalImageTransferExecutionError.textDeliveryFailed)
                }
                return
            }
            guard operation.finish() else { return }
            onSuccess()
        case .failure(let error):
            guard operation.finish() else { return }
            onFailure(error)
        }
    }

    private static func sendTextSegments(
        _ segments: [String],
        index: Int,
        interSegmentDelay: TimeInterval,
        operation: TerminalImageTransferOperation,
        insertText: @escaping (String) -> Bool,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void,
        shouldContinue: @escaping () -> Bool = { true },
        onFailure: @escaping (Error) -> Void,
        onSuccess: @escaping () -> Void = {}
    ) {
        guard !operation.isCancelled else { return }
        guard shouldContinue() else {
            if operation.cancel() {
                onFailure(
                    TerminalImageTransferExecutionError.unavailable(.disconnectedRemoteSession)
                )
            }
            return
        }
        guard index < segments.count else {
            if operation.finish() {
                onSuccess()
            }
            return
        }

        let segment = segments[index]
        if !segment.isEmpty, !insertText(segment) {
            if operation.cancel() {
                onFailure(TerminalImageTransferExecutionError.textDeliveryFailed)
            }
            return
        }

        let nextIndex = index + 1
        guard nextIndex < segments.count else {
            if operation.finish() {
                onSuccess()
            }
            return
        }

        scheduleAfter(interSegmentDelay) {
            sendTextSegments(
                segments,
                index: nextIndex,
                interSegmentDelay: interSegmentDelay,
                operation: operation,
                insertText: insertText,
                scheduleAfter: scheduleAfter,
                shouldContinue: shouldContinue,
                onFailure: onFailure,
                onSuccess: onSuccess
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
        guard let workspace = owningWorkspace() else {
            return .unavailable(.detachedWindow)
        }
        // UniConnect never guesses a connection kind. A starter/detached window with no
        // persisted box profile must fail closed instead of inheriting cmux's legacy remote
        // workspace classification and accidentally uploading (or exposing) a local path.
        if UniConnectCoordinator.isEnabled, workspace.uniConnectProfile == nil {
            return .unavailable(.detachedWindow)
        }
        switch workspace.uniConnectProfile?.kind {
        case .local:
            return .local
        case .ssh:
            if workspace.uniConnectDisconnectedPanelIds.contains(id) {
                return .unavailable(.disconnectedSSHWindow)
            }
            guard let credentialId = workspace.uniConnectProfile?.credentialId,
                  let credentialRecord = UniConnectVault.shared.credentialRecord(
                      for: credentialId
                  ) else {
                return .unavailable(.missingSSHConnectCommand)
            }
            guard let session = UniConnectSSH.detectedSession(
                fromCredentialRecord: credentialRecord
            ) else {
                return .unavailable(.unparseableSSHConnectCommand)
            }
            return .remote(.detectedSSH(session))
        case nil:
            guard workspace.isRemoteWorkspace else { return .local }
            guard workspace.remoteConnectionState == .connected else {
                return .unavailable(.disconnectedRemoteSession)
            }
            return .remote(.workspaceRemote)
        }
    }

    @MainActor
    func canContinueImageTransfer(to expectedTarget: TerminalRemoteUploadTarget) -> Bool {
        resolvedImageTransferTarget() == .remote(expectedTarget)
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
