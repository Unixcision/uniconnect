import AppKit

enum FileExplorerTerminalPathInsertion {
    static func insertedText(forPaths paths: [String]) -> String {
        TerminalImageTransferPlanner.insertedText(forPathStrings: paths)
    }

    static func insertedText(forPaths paths: [String], relativeToRootPath rootPath: String) -> String {
        insertedText(forPaths: paths.map { relativePath(for: $0, rootPath: rootPath) })
    }

    static func relativePath(for path: String, rootPath: String) -> String {
        let normalizedPath = normalizedFileSystemPath(path)
        guard !rootPath.isEmpty else { return normalizedPath }
        let normalizedRootPath = normalizedFileSystemPath(rootPath)
        if normalizedPath == normalizedRootPath { return "." }
        let normalizedRoot = normalizedRootPath == "/" ? "/" : normalizedRootPath + "/"
        if normalizedPath.hasPrefix(normalizedRoot) {
            return String(normalizedPath.dropFirst(normalizedRoot.count))
        }
        return normalizedPath
    }

    private static func normalizedFileSystemPath(_ path: String) -> String {
        let path = pathWithoutTrailingSlashes(path)
        guard path.hasPrefix("/") else { return path }
        return macOSDisplayPath(
            pathWithoutTrailingSlashes(URL(fileURLWithPath: path).standardizedFileURL.path)
        )
    }

    private static func macOSDisplayPath(_ path: String) -> String {
        let rewrites = [
            (privatePath: "/private/tmp", displayPath: "/tmp"),
            (privatePath: "/private/var", displayPath: "/var"),
            (privatePath: "/private/etc", displayPath: "/etc"),
        ]
        for rewrite in rewrites {
            if path == rewrite.privatePath {
                return rewrite.displayPath
            }
            if path.hasPrefix(rewrite.privatePath + "/") {
                return rewrite.displayPath + String(path.dropFirst(rewrite.privatePath.count))
            }
        }
        return path
    }

    private static func pathWithoutTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    @MainActor
    @discardableResult
    static func insert(
        paths: [String],
        relativeToRootPath rootPath: String? = nil,
        origin: TerminalImageTransferPlanner.PathOrigin? = nil,
        intoTerminalFor window: NSWindow?
    ) -> Bool {
        let insertionPaths: [String]
        if let rootPath {
            insertionPaths = paths.map { relativePath(for: $0, rootPath: rootPath) }
        } else {
            insertionPaths = paths
        }
        guard !insertionPaths.isEmpty else { return false }

        guard let terminalPanel = targetTerminalPanel(for: window) else { return false }
        let target = terminalPanel.surface.resolvedImageTransferTarget()
        let resolvedOrigin = origin ?? .localFileSystem(
            paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        )
        let plan = TerminalImageTransferPlanner.planPathInsertion(
            paths: insertionPaths,
            origin: resolvedOrigin,
            target: target
        )
        let isRejected: Bool
        switch plan {
        case .unavailable, .reject:
            isRejected = true
        case .insertText, .insertTextSegments, .uploadFiles:
            isRejected = false
        }

        let operation: TerminalImageTransferOperation?
        let destinationIsAvailable: () -> Bool
        if case .uploadFiles(_, let remoteTarget, _) = plan {
            let uploadOperation = TerminalImageTransferOperation()
            operation = uploadOperation
            destinationIsAvailable = { [weak surface = terminalPanel.surface] in
                surface?.canContinueImageTransfer(to: remoteTarget) == true
            }
            terminalPanel.hostedView.beginImageTransferIndicator(
                for: uploadOperation,
                isDestinationAvailable: destinationIsAvailable,
                onCancel: {}
            )
        } else {
            operation = nil
            destinationIsAvailable = { true }
        }

        TerminalImageTransferPlanner.execute(
            plan: plan,
            operation: operation,
            uploadWorkspaceRemote: { [weak surface = terminalPanel.surface] fileURLs, operation, finish in
                guard let workspace = MainActor.assumeIsolated({ surface?.owningWorkspace() }) else {
                    finish(.failure(TerminalImageTransferExecutionError.unavailable(.disconnectedRemoteSession)))
                    return
                }
                workspace.uploadDroppedFilesForRemoteTerminal(
                    fileURLs,
                    operation: operation,
                    completion: finish
                )
            },
            uploadDetectedSSH: { session, fileURLs, operation, finish in
                session.uploadDroppedFiles(
                    fileURLs,
                    operation: operation,
                    completion: finish
                )
            },
            insertText: { [weak terminalPanel] text in
                terminalPanel?.sendText(text) == true
            },
            isDestinationAvailable: destinationIsAvailable,
            onSuccess: { [weak terminalPanel] in
                if let operation {
                    terminalPanel?.hostedView.endImageTransferIndicator(for: operation)
                }
            },
            onFailure: { [weak terminalPanel] error in
                if let operation {
                    terminalPanel?.hostedView.endImageTransferIndicator(for: operation)
                }
                TerminalImageTransferErrorPresenter.present(error)
            }
        )
        return !isRejected
    }

    @MainActor
    private static func targetTerminalPanel(for window: NSWindow?) -> TerminalPanel? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        if let window,
           let terminalPanel = appDelegate.contextForMainTerminalWindow(window)?.tabManager.selectedWorkspace?.focusedTerminalPanel {
            return terminalPanel
        }
        if let window,
           let windowId = appDelegate.mainWindowId(from: window),
           let terminalPanel = appDelegate.tabManagerFor(windowId: windowId)?.selectedWorkspace?.focusedTerminalPanel {
            return terminalPanel
        }
        return appDelegate.tabManager?.selectedWorkspace?.focusedTerminalPanel
    }
}

extension NSMenu {
    func addFileExplorerInsertPathItems(
        target: AnyObject,
        representedObject: Any,
        insertAction: Selector,
        insertRelativeAction: Selector
    ) {
        let insertPathItem = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.insertPath", defaultValue: "Insert Path"),
            action: insertAction,
            keyEquivalent: ""
        )
        insertPathItem.target = target
        insertPathItem.representedObject = representedObject
        addItem(insertPathItem)

        let insertRelativePathItem = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.insertRelativePath", defaultValue: "Insert Relative Path"),
            action: insertRelativeAction,
            keyEquivalent: ""
        )
        insertRelativePathItem.target = target
        insertRelativePathItem.representedObject = representedObject
        addItem(insertRelativePathItem)
    }
}

extension FileExplorerPanelView.Coordinator {
    @MainActor
    private func contextMenuNodes(clicked node: FileExplorerNode) -> [FileExplorerNode] {
        guard let outlineView else { return [node] }
        let clickedRow = outlineView.clickedRow
        let selectedRows = outlineView.selectedRowIndexes
        guard clickedRow >= 0, selectedRows.contains(clickedRow) else {
            return [node]
        }
        let nodes = selectedRows.compactMap { row -> FileExplorerNode? in
            guard row >= 0, row < outlineView.numberOfRows else { return nil }
            return outlineView.item(atRow: row) as? FileExplorerNode
        }
        return nodes.isEmpty ? [node] : nodes
    }

    @MainActor
    @objc func contextMenuInsertPath(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        FileExplorerTerminalPathInsertion.insert(
            paths: contextMenuNodes(clicked: node).map(\.path),
            origin: store.provider is SSHFileExplorerProvider ? .remoteSession : nil,
            intoTerminalFor: outlineView?.window ?? containerView?.window
        )
    }

    @MainActor
    @objc func contextMenuInsertRelativePath(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        FileExplorerTerminalPathInsertion.insert(
            paths: contextMenuNodes(clicked: node).map(\.path),
            relativeToRootPath: store.rootPath,
            origin: store.provider is SSHFileExplorerProvider ? .remoteSession : nil,
            intoTerminalFor: outlineView?.window ?? containerView?.window
        )
    }
}

extension FileExplorerContainerView {
    @MainActor
    private func searchResultsForContextMenu(row: Int) -> [FileSearchResult] {
        guard row >= 0, row < searchSnapshot.results.count else { return [] }
        let selectedRows = searchResultsView.selectedRowIndexes
        guard selectedRows.contains(row) else {
            return [searchSnapshot.results[row]]
        }
        let results = selectedRows.compactMap { selectedRow -> FileSearchResult? in
            guard selectedRow >= 0, selectedRow < searchSnapshot.results.count else { return nil }
            return searchSnapshot.results[selectedRow]
        }
        return results.isEmpty ? [searchSnapshot.results[row]] : results
    }

    @MainActor
    @objc func contextMenuInsertSearchResultPath(_ sender: NSMenuItem) {
        guard let row = (sender.representedObject as? NSNumber)?.intValue else { return }
        FileExplorerTerminalPathInsertion.insert(
            paths: searchResultsForContextMenu(row: row).map(\.path),
            origin: terminalPathInsertionOrigin,
            intoTerminalFor: window
        )
    }

    @MainActor
    @objc func contextMenuInsertSearchResultRelativePath(_ sender: NSMenuItem) {
        guard let row = (sender.representedObject as? NSNumber)?.intValue else { return }
        FileExplorerTerminalPathInsertion.insert(
            paths: searchResultsForContextMenu(row: row).map(\.path),
            relativeToRootPath: currentRootPath,
            origin: terminalPathInsertionOrigin,
            intoTerminalFor: window
        )
    }
}
