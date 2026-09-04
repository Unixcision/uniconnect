import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CommandPaletteShortcutCustomizationTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!
    private var settingsDirectoryURL: URL!
    private var savedCommandPaletteNext: Any?
    private var savedCommandPalettePrevious: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 30
        let defaults = UserDefaults.standard
        savedCommandPaletteNext = defaults.object(forKey: KeyboardShortcutSettings.Action.commandPaletteNext.defaultsKey)
        savedCommandPalettePrevious = defaults.object(forKey: KeyboardShortcutSettings.Action.commandPalettePrevious.defaultsKey)
        defaults.removeObject(forKey: KeyboardShortcutSettings.Action.commandPaletteNext.defaultsKey)
        defaults.removeObject(forKey: KeyboardShortcutSettings.Action.commandPalettePrevious.defaultsKey)
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        settingsDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectoryURL, withIntermediateDirectories: true)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsDirectoryURL.appendingPathComponent("uniconnect.json").path,
            fallbackPath: nil,
            startWatching: false
        )
        #if DEBUG
        KeyboardShortcutRecorderActivity.resetForTesting()
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
    }

    override func tearDown() {
        #if DEBUG
        KeyboardShortcutRecorderActivity.resetForTesting()
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
        restoreDefault(savedCommandPaletteNext, forKey: KeyboardShortcutSettings.Action.commandPaletteNext.defaultsKey)
        restoreDefault(savedCommandPalettePrevious, forKey: KeyboardShortcutSettings.Action.commandPalettePrevious.defaultsKey)
        savedCommandPaletteNext = nil
        savedCommandPalettePrevious = nil
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        if let settingsDirectoryURL {
            try? FileManager.default.removeItem(at: settingsDirectoryURL)
        }
        super.tearDown()
    }

    private func restoreDefault(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testUniConnectPaletteKeepsProductActionsAndFiltersInheritedCmuxSurfaces() {
        let kept = [
            "palette.newWorkspace",
            "palette.newTerminalTab",
            "palette.renameWorkspace",
            "palette.renameTab",
            "palette.terminalSplitRight",
            "palette.uniConnect.lock",
            "palette.uniConnect.persistNow",
            "palette.uniConnect.restoreBackup",
            "palette.uniConnect.reconnectDropped",
            "palette.uniConnect.updateClaudeWindow",
            "palette.uniConnect.saveSeedTemplate",
        ]
        let filtered = [
            "palette.newWindow",
            "palette.openFolder",
            "palette.openFolderInVSCodeInline",
            "palette.newBrowserTab",
            "palette.browserReload",
            "palette.showRightSidebarFiles",
            "palette.openFilesPane",
            "palette.openDiffViewer",
            "palette.openTaskManager",
            "palette.checkForUpdates",
            "palette.applyUpdateIfAvailable",
            "palette.attemptUpdate",
            "palette.disableBrowser",
            "palette.makeDefaultTerminal",
            "palette.moveTabToNewWorkspace",
            "palette.forkAgentConversationNewWorkspace",
            "palette.terminalSplitBrowserRight",
            "palette.terminalOpenDirectory.vscode",
            "palette.copyIdentifiers",
            "palette.toggleSetting.browserOpenAuthLinksInDefaultBrowser",
            "palette.extensionSidebar.builtin",
            "palette.vscodeServeWebRestart",
        ]

        XCTAssertTrue(kept.allSatisfy { ContentView.uniConnectAllowsCommandPaletteContribution($0) })
        XCTAssertTrue(filtered.allSatisfy { !ContentView.uniConnectAllowsCommandPaletteContribution($0) })
        XCTAssertEqual(ContentView.commandPaletteShortcutAction(forCommandID: "palette.uniConnect.lock"), .lockApp)
        XCTAssertEqual(ContentView.commandPaletteShortcutAction(forCommandID: "palette.uniConnect.persistNow"), .persistNow)
        XCTAssertNil(ContentView.commandPaletteShortcutAction(forCommandID: "palette.uniConnect.restoreBackup"))
        XCTAssertEqual(ContentView.commandPaletteShortcutAction(forCommandID: "palette.uniConnect.reconnectDropped"), .reconnectDroppedWindows)
        XCTAssertEqual(ContentView.commandPaletteShortcutAction(forCommandID: "palette.uniConnect.updateClaudeWindow"), .updateClaudeInWindow)
    }

    func testFieldEditorMoveCommandHonorsClearedCommandPalettePreviousShortcut() {
        guard let controlPEvent = makeKeyDownEvent(
            key: "\u{10}",
            modifiers: [.control],
            keyCode: 35,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Ctrl+P event")
            return
        }

        XCTAssertNil(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: controlPEvent,
                previousShortcut: nil
            ),
            "The field editor must not translate cleared Ctrl+P into palette navigation"
        )
    }

    func testKeyboardNavigationDefaultLookupHonorsClearedCommandPalettePreviousShortcut() {
        withTemporaryCommandPalettePreviousShortcut {
            KeyboardShortcutSettings.unbindShortcut(for: .commandPalettePrevious)
            XCTAssertNil(KeyboardShortcutSettings.shortcutIfBound(for: .commandPalettePrevious))

            XCTAssertNil(
                commandPaletteSelectionDeltaForKeyboardNavigation(
                    flags: [.control],
                    chars: "\u{10}",
                    keyCode: 35
                ),
                "Default keyboard-navigation lookup must not fall back to hardcoded Ctrl+P after unbinding"
            )
        }
    }

    func testKeyboardNavigationDefaultLookupHonorsRemappedCommandPalettePreviousShortcut() {
        withTemporaryCommandPalettePreviousShortcut {
            let remappedPrevious = StoredShortcut(key: "u", command: false, shift: false, option: false, control: true)
            KeyboardShortcutSettings.setShortcut(remappedPrevious, for: .commandPalettePrevious)

            XCTAssertNil(
                commandPaletteSelectionDeltaForKeyboardNavigation(
                    flags: [.control],
                    chars: "\u{10}",
                    keyCode: 35
                )
            )
            XCTAssertEqual(
                commandPaletteSelectionDeltaForKeyboardNavigation(
                    flags: [.control],
                    chars: "\u{15}",
                    keyCode: 32
                ),
                -1
            )
        }
    }

    func testFieldEditorMoveCommandWithoutEventHonorsClearedCommandPalettePreviousShortcut() {
        XCTAssertNil(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: nil,
                previousShortcut: nil
            ),
            "The field editor must not use AppKit moveUp fallback after Ctrl+P is cleared"
        )
    }

    func testFieldEditorMoveCommandWithoutEventOnlyUsesDefaultCommandPalettePreviousShortcut() {
        let remappedPrevious = StoredShortcut(key: "u", command: false, shift: false, option: false, control: true)
        XCTAssertNil(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: nil,
                previousShortcut: remappedPrevious
            )
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: nil
            ),
            -1
        )
    }

    func testFieldEditorMoveCommandHonorsRemappedCommandPalettePreviousShortcut() {
        let remappedPrevious = StoredShortcut(
            key: "u",
            command: false,
            shift: false,
            option: false,
            control: true
        )

        guard let controlPEvent = makeKeyDownEvent(
            key: "\u{10}",
            modifiers: [.control],
            keyCode: 35,
            windowNumber: 0
        ),
        let controlUEvent = makeKeyDownEvent(
            key: "\u{15}",
            modifiers: [.control],
            keyCode: 32,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct command-palette navigation events")
            return
        }

        XCTAssertNil(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: controlPEvent,
                previousShortcut: remappedPrevious
            )
        )
        XCTAssertEqual(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: controlUEvent,
                previousShortcut: remappedPrevious
            ),
            -1
        )
    }

    func testFieldEditorMoveCommandAlwaysKeepsPlainArrowNavigation() {
        guard let upArrowEvent = makeKeyDownEvent(
            key: String(UnicodeScalar(NSUpArrowFunctionKey)!),
            modifiers: [],
            keyCode: 126,
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct Up Arrow event")
            return
        }

        XCTAssertEqual(
            commandPaletteSelectionDeltaForFieldEditorCommand(
                #selector(NSResponder.moveUp(_:)),
                event: upArrowEvent,
                previousShortcut: nil
            ),
            -1
        )
    }

    func testRemappedCommandPalettePreviousShortcutDoesNotConsumeControlP() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withCommandPaletteFieldEditor(appDelegate: appDelegate) { window, _ in
            withTemporaryCommandPalettePreviousShortcut {
                let remappedPrevious = StoredShortcut(key: "u", command: false, shift: false, option: false, control: true)
                KeyboardShortcutSettings.setShortcut(remappedPrevious, for: .commandPalettePrevious)
                XCTAssertEqual(KeyboardShortcutSettings.shortcutIfBound(for: .commandPalettePrevious), remappedPrevious)

                guard let controlPEvent = makeKeyDownEvent(
                    key: "\u{10}",
                    modifiers: [.control],
                    keyCode: 35,
                    windowNumber: window.windowNumber
                ) else {
                    XCTFail("Failed to construct Ctrl+P event")
                    return
                }
                var observedControlP = false
                let controlPToken = NotificationCenter.default.addObserver(
                    forName: .commandPaletteMoveSelection,
                    object: window,
                    queue: nil
                ) { _ in
                    observedControlP = true
                }

                #if DEBUG
                XCTAssertFalse(appDelegate.debugHandleCustomShortcut(event: controlPEvent))
                #else
                XCTFail("debugHandleCustomShortcut is only available in DEBUG")
                #endif

                NotificationCenter.default.removeObserver(controlPToken)
                XCTAssertFalse(observedControlP)

                var observedDelta: Int?
                let controlUToken = NotificationCenter.default.addObserver(
                    forName: .commandPaletteMoveSelection,
                    object: window,
                    queue: nil
                ) { notification in
                    observedDelta = notification.userInfo?["delta"] as? Int
                }
                defer { NotificationCenter.default.removeObserver(controlUToken) }

                guard let controlUEvent = makeKeyDownEvent(
                    key: "\u{15}",
                    modifiers: [.control],
                    keyCode: 32,
                    windowNumber: window.windowNumber
                ) else {
                    XCTFail("Failed to construct Ctrl+U event")
                    return
                }

                #if DEBUG
                XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: controlUEvent))
                #else
                XCTFail("debugHandleCustomShortcut is only available in DEBUG")
                #endif

                XCTAssertEqual(observedDelta, -1)
            }
        }
    }

    func testUnboundCommandPalettePreviousShortcutLetsControlPPassThrough() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withCommandPaletteFieldEditor(appDelegate: appDelegate) { window, _ in
            withTemporaryCommandPalettePreviousShortcut {
                KeyboardShortcutSettings.unbindShortcut(for: .commandPalettePrevious)
                XCTAssertNil(KeyboardShortcutSettings.shortcutIfBound(for: .commandPalettePrevious))

                var observedMove = false
                let moveToken = NotificationCenter.default.addObserver(
                    forName: .commandPaletteMoveSelection,
                    object: window,
                    queue: nil
                ) { _ in
                    observedMove = true
                }
                defer { NotificationCenter.default.removeObserver(moveToken) }

                guard let controlPEvent = makeKeyDownEvent(
                    key: "\u{10}",
                    modifiers: [.control],
                    keyCode: 35,
                    windowNumber: window.windowNumber
                ) else {
                    XCTFail("Failed to construct Ctrl+P event")
                    return
                }

                #if DEBUG
                XCTAssertFalse(
                    appDelegate.debugHandleCustomShortcut(event: controlPEvent),
                    "Unbound Ctrl+P should stay on the normal keyDown path so the terminal can receive ^P"
                )
                #else
                XCTFail("debugHandleCustomShortcut is only available in DEBUG")
                #endif

                XCTAssertFalse(observedMove)
            }
        }
    }

    func testChordedCommandPaletteNextShortcutMovesSelection() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withCommandPaletteFieldEditor(appDelegate: appDelegate) { window, _ in
            withTemporaryCommandPaletteShortcut(.commandPaletteNext) {
                KeyboardShortcutSettings.setShortcut(
                    StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "n"),
                    for: .commandPaletteNext
                )
                var observedDeltas: [Int] = []
                var observedWindow: NSWindow?
                let moveToken = NotificationCenter.default.addObserver(forName: .commandPaletteMoveSelection, object: window, queue: nil) { notification in
                    observedWindow = notification.object as? NSWindow
                    if let delta = notification.userInfo?["delta"] as? Int {
                        observedDeltas.append(delta)
                    }
                }
                defer { NotificationCenter.default.removeObserver(moveToken) }

                guard let prefixEvent = makeKeyDownEvent(key: "b", modifiers: [.control], keyCode: 11, windowNumber: window.windowNumber),
                      let actionEvent = makeKeyDownEvent(key: "n", modifiers: [], keyCode: 45, windowNumber: window.windowNumber) else {
                    XCTFail("Failed to construct command-palette chord events")
                    return
                }

                #if DEBUG
                XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
                XCTAssertEqual(observedDeltas, [], "Chord prefix must arm without moving selection")
                XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: actionEvent))
                #else
                XCTFail("debugHandleCustomShortcut is only available in DEBUG")
                #endif

                XCTAssertEqual(observedWindow?.windowNumber, window.windowNumber)
                XCTAssertEqual(observedDeltas, [1])
            }
        }
    }

    func testWindowPerformKeyEquivalentRoutesHorizontalArrowsToCommandPaletteFieldEditor() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withCommandPaletteFieldEditor(appDelegate: appDelegate) { window, fieldEditor in
            guard let leftArrowEvent = makeKeyDownEvent(
                key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                modifiers: [],
                keyCode: 123,
                windowNumber: window.windowNumber
            ),
            let rightArrowEvent = makeKeyDownEvent(
                key: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                modifiers: [],
                keyCode: 124,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct horizontal arrow events")
                return
            }

            XCTAssertTrue(window.performKeyEquivalent(with: leftArrowEvent))
            XCTAssertTrue(window.performKeyEquivalent(with: rightArrowEvent))
            XCTAssertEqual(fieldEditor.keyDownKeyCodes, [123, 124])
        }
    }

    func testWindowPerformKeyEquivalentDoesNotRouteHorizontalArrowsWhenPaletteOverlayIsTransparent() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withVisibleCommandPaletteOverlay(appDelegate: appDelegate) { window, overlayContainer in
            let fieldEditor = CommandPaletteShortcutFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            fieldEditor.isFieldEditor = true
            overlayContainer.addSubview(fieldEditor)
            defer { fieldEditor.removeFromSuperview() }

            XCTAssertTrue(window.makeFirstResponder(fieldEditor))
            XCTAssertTrue(window.firstResponder === fieldEditor)

            overlayContainer.alphaValue = 0

            guard let leftArrowEvent = makeKeyDownEvent(
                key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                modifiers: [],
                keyCode: 123,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct horizontal arrow event")
                return
            }

            XCTAssertFalse(window.performKeyEquivalent(with: leftArrowEvent))
            XCTAssertEqual(fieldEditor.keyDownKeyCodes, [])
        }
    }

    func testWindowPerformKeyEquivalentDoesNotStealHorizontalArrowsFromNonPaletteFieldEditor() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        withVisibleCommandPaletteOverlay(appDelegate: appDelegate) { window, _ in
            guard let contentView = window.contentView else {
                XCTFail("Expected test window content view")
                return
            }

            let outsideOwnerView = NSView(frame: contentView.bounds)
            contentView.addSubview(outsideOwnerView)
            defer { outsideOwnerView.removeFromSuperview() }

            let fieldEditor = CommandPaletteShortcutFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            fieldEditor.isFieldEditor = true
            outsideOwnerView.addSubview(fieldEditor)
            defer { fieldEditor.removeFromSuperview() }

            XCTAssertTrue(window.makeFirstResponder(fieldEditor))
            XCTAssertTrue(window.firstResponder === fieldEditor)
            fieldEditor.nextResponder = outsideOwnerView

            guard let leftArrowEvent = makeKeyDownEvent(
                key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                modifiers: [],
                keyCode: 123,
                windowNumber: window.windowNumber
            ) else {
                XCTFail("Failed to construct horizontal arrow event")
                return
            }

            XCTAssertFalse(window.performKeyEquivalent(with: leftArrowEvent))
            XCTAssertEqual(fieldEditor.keyDownKeyCodes, [])
        }
    }

    private func withCommandPaletteFieldEditor(
        appDelegate: AppDelegate,
        _ body: (NSWindow, CommandPaletteShortcutFieldEditor) -> Void
    ) {
        withVisibleCommandPaletteOverlay(appDelegate: appDelegate) { window, overlayContainer in
            let fieldEditor = CommandPaletteShortcutFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            fieldEditor.isFieldEditor = true
            overlayContainer.addSubview(fieldEditor)
            appDelegate.setCommandPaletteVisible(true, for: window)
            window.displayIfNeeded()
            XCTAssertTrue(window.makeFirstResponder(fieldEditor))

            defer {
                appDelegate.setCommandPaletteVisible(false, for: window)
                fieldEditor.removeFromSuperview()
            }

            body(window, fieldEditor)
        }
    }

    private func withVisibleCommandPaletteOverlay(
        appDelegate: AppDelegate,
        _ body: (NSWindow, NSView) -> Void
    ) {
        let previousTabManager = appDelegate.tabManager
        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        defer {
            window.orderOut(nil)
            window.close()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            appDelegate.tabManager = previousTabManager
        }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        guard let contentView = window.contentView else {
            XCTFail("Expected test window content view")
            return
        }
        let overlayHost = contentView.superview ?? contentView

        let overlayContainer = NSView(frame: overlayHost.bounds)
        overlayContainer.identifier = commandPaletteOverlayContainerIdentifier
        overlayContainer.alphaValue = 1
        overlayContainer.isHidden = false
        overlayHost.addSubview(overlayContainer)

        defer {
            appDelegate.setCommandPaletteVisible(false, for: window)
            overlayContainer.removeFromSuperview()
        }

        body(window, overlayContainer)
    }

    private func withTemporaryCommandPalettePreviousShortcut(_ body: () -> Void) {
        withTemporaryCommandPaletteShortcut(.commandPalettePrevious, body)
    }

    private func withTemporaryCommandPaletteShortcut(
        _ action: KeyboardShortcutSettings.Action,
        _ body: () -> Void
    ) {
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        body()
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

}

private final class CommandPaletteShortcutFieldEditor: NSTextView {
    var keyDownKeyCodes: [UInt16] = []

    override func hasMarkedText() -> Bool {
        false
    }

    override func keyDown(with event: NSEvent) {
        keyDownKeyCodes.append(event.keyCode)
    }
}
