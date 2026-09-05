import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class KeyboardShortcutContextTests: XCTestCase {
    func testFocusedSSHReconnectAndBrowserReloadShareCommandRByContextWhileRenameRemainsConfigurable() {
        let renameTabShortcut = KeyboardShortcutSettings.Action.renameTab.defaultShortcut
        let focusedReconnectShortcut = KeyboardShortcutSettings.Action.reconnectFocusedSSHWindow.defaultShortcut
        let configuredBrowserReload = StoredShortcut(
            key: "r",
            command: true,
            shift: false,
            option: false,
            control: false
        )

        XCTAssertEqual(focusedReconnectShortcut, configuredBrowserReload)
        XCTAssertEqual(renameTabShortcut, .unbound)
        XCTAssertEqual(KeyboardShortcutSettings.Action.browserReload.defaultShortcut, configuredBrowserReload)
        XCTAssertEqual(KeyboardShortcutSettings.Action.reconnectFocusedSSHWindow.shortcutContext, .nonBrowserPanel)
        XCTAssertFalse(KeyboardShortcutSettings.settingsVisibleActions.contains(.browserReload))
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.shortcutContext, .nonBrowserPanel)
        XCTAssertEqual(KeyboardShortcutSettings.Action.browserReload.shortcutContext, .browserPanel)
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.reconnectFocusedSSHWindow.conflicts(
                with: configuredBrowserReload,
                proposedAction: .browserReload,
                configuredShortcut: focusedReconnectShortcut
            )
        )
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.browserReload.conflicts(
                with: focusedReconnectShortcut,
                proposedAction: .reconnectFocusedSSHWindow,
                configuredShortcut: configuredBrowserReload
            )
        )
        XCTAssertTrue(
            KeyboardShortcutSettings.Action.reconnectFocusedSSHWindow.conflicts(
                with: focusedReconnectShortcut,
                proposedAction: .renameWorkspace,
                configuredShortcut: focusedReconnectShortcut
            )
        )
    }

    func testRenameTabCanReassignCommandRAfterUnbindingWithoutBrowserReloadConflict() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("uniconnect.json", isDirectory: false)
        try writeSettingsFile("{}", to: settingsFileURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let commandR = StoredShortcut(key: "r", command: true, shift: false, option: false, control: false)
        XCTAssertEqual(commandR, KeyboardShortcutSettings.Action.reconnectFocusedSSHWindow.defaultShortcut)
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.defaultShortcut, .unbound)
        XCTAssertEqual(KeyboardShortcutSettings.Action.browserReload.defaultShortcut, commandR)

        KeyboardShortcutSettings.clearShortcut(for: .reconnectFocusedSSHWindow)
        KeyboardShortcutSettings.setShortcut(commandR, for: .renameTab)
        KeyboardShortcutSettings.clearShortcut(for: .renameTab)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .renameTab), .unbound)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .browserReload), commandR)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.renameTab.normalizedRecordedShortcutResult(commandR),
            .accepted(commandR)
        )

        KeyboardShortcutSettings.setShortcut(commandR, for: .renameTab)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .renameTab), commandR)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .browserReload), commandR)
    }

    func testSwapPathIgnoresNonOverlappingShortcutContexts() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("uniconnect.json", isDirectory: false)
        try writeSettingsFile("{}", to: settingsFileURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let commandR = KeyboardShortcutSettings.Action.reconnectFocusedSSHWindow.defaultShortcut
        KeyboardShortcutSettings.clearShortcut(for: .reconnectFocusedSSHWindow)
        KeyboardShortcutSettings.setShortcut(commandR, for: .browserReload)

        let didSwap = KeyboardShortcutSettings.swapShortcutConflict(
            proposedShortcut: commandR,
            currentAction: .renameTab,
            conflictingAction: .browserReload,
            previousShortcut: .unbound
        )

        XCTAssertFalse(didSwap)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .renameTab), .unbound)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .browserReload), commandR)
        XCTAssertNil(
            ShortcutRecorderValidationPresentation(
                attempt: ShortcutRecorderRejectedAttempt(
                    reason: .conflictsWithAction(.browserReload),
                    proposedShortcut: commandR
                ),
                action: .renameTab,
                currentShortcut: .unbound,
                shortcutForAction: { $0.defaultShortcut }
            )
        )
    }

    func testLegacyStoredRenameBindingsSurviveFocusedReconnectDefaultChange() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        let settingsFileURL = directoryURL.appendingPathComponent("uniconnect.json")
        try writeSettingsFile("{}", to: settingsFileURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let suiteName = "uniconnect-shortcut-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let commandR = StoredShortcut(key: "r", command: true, shift: false, option: false, control: false)
        defaults.set(
            try JSONEncoder().encode(commandR),
            forKey: KeyboardShortcutSettings.Action.renameTab.defaultsKey
        )

        KeyboardShortcutSettings.migrateLegacyRenameCommandRIfNeeded(defaults: defaults)

        XCTAssertEqual(
            try JSONDecoder().decode(
                StoredShortcut.self,
                from: try XCTUnwrap(defaults.data(
                    forKey: KeyboardShortcutSettings.Action.renameTab.defaultsKey
                ))
            ),
            commandR
        )
        XCTAssertNil(defaults.object(
            forKey: KeyboardShortcutSettings.Action.reconnectFocusedSSHWindow.defaultsKey
        ))
        XCTAssertTrue(defaults.bool(forKey: KeyboardShortcutSettings.focusedSSHReconnectCommandRMigrationKey))

        let customRename = StoredShortcut(key: "e", command: true, shift: false, option: true, control: false)
        let secondSuiteName = "uniconnect-shortcut-migration-custom-\(UUID().uuidString)"
        let customDefaults = try XCTUnwrap(UserDefaults(suiteName: secondSuiteName))
        defer { customDefaults.removePersistentDomain(forName: secondSuiteName) }
        customDefaults.set(
            try JSONEncoder().encode(customRename),
            forKey: KeyboardShortcutSettings.Action.renameTab.defaultsKey
        )

        KeyboardShortcutSettings.migrateLegacyRenameCommandRIfNeeded(defaults: customDefaults)

        XCTAssertEqual(
            try JSONDecoder().decode(
                StoredShortcut.self,
                from: try XCTUnwrap(customDefaults.data(
                    forKey: KeyboardShortcutSettings.Action.renameTab.defaultsKey
                ))
            ),
            customRename
        )
        XCTAssertNil(customDefaults.object(
            forKey: KeyboardShortcutSettings.Action.reconnectFocusedSSHWindow.defaultsKey
        ))
    }

    func testRenameWorkspaceIsScopedOutsideBrowserPanels() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.shortcutContext, .nonBrowserPanel)
    }

    func testRightSidebarContextIsOnlyAvailableWhenRightSidebarHasFocus() {
        let context = KeyboardShortcutSettings.Action.switchRightSidebarToFiles.shortcutContext

        XCTAssertEqual(context, .rightSidebarFocus)
        XCTAssertFalse(context.isAvailable(focusedBrowserPanel: false, focusedMarkdownPanel: false, rightSidebarFocused: false))
        XCTAssertTrue(context.isAvailable(focusedBrowserPanel: false, focusedMarkdownPanel: false, rightSidebarFocused: true))
        XCTAssertFalse(
            KeyboardShortcutSettings.Action.renameTab.shortcutContext
                .isAvailable(focusedBrowserPanel: false, focusedMarkdownPanel: false, rightSidebarFocused: true)
        )
        XCTAssertTrue(context.overlaps(KeyboardShortcutSettings.Action.commandPalette.shortcutContext))
        XCTAssertFalse(context.overlaps(KeyboardShortcutSettings.Action.renameTab.shortcutContext))
    }

    func testReactGrabStaysApplicationScopedForTerminalPastebackRouting() {
        let reactGrab = KeyboardShortcutSettings.Action.toggleReactGrab
        let commandShiftG = StoredShortcut(
            key: "g",
            command: true,
            shift: true,
            option: false,
            control: false
        )

        XCTAssertEqual(reactGrab.shortcutContext, .application)
        XCTAssertEqual(reactGrab.defaultShortcut, commandShiftG)
    }

    func testLegacyBrowserFocusModeCanBeConfiguredWithoutCollidingWithSplitZoom() {
        let focusMode = KeyboardShortcutSettings.Action.toggleBrowserFocusMode

        // Scoped to browser panels so it only claims the key when a browser is focused.
        XCTAssertEqual(focusMode.shortcutContext, .browserPanel)

        XCTAssertEqual(focusMode.defaultShortcut, .unbound)
        XCTAssertFalse(KeyboardShortcutSettings.settingsVisibleActions.contains(focusMode))
        let focusModeShortcut = StoredShortcut(
            key: "\r",
            command: true,
            shift: false,
            option: true,
            control: false
        )
        XCTAssertNotEqual(
            focusModeShortcut,
            KeyboardShortcutSettings.Action.toggleSplitZoom.defaultShortcut
        )
        XCTAssertFalse(
            focusMode.conflicts(
                with: KeyboardShortcutSettings.Action.toggleSplitZoom.defaultShortcut,
                proposedAction: .toggleSplitZoom,
                configuredShortcut: focusModeShortcut
            )
        )
    }

    func testMarkdownZoomIsScopedToFocusedMarkdownPanelAndDoesNotCollideWithBrowserZoom() {
        for action in [
            KeyboardShortcutSettings.Action.markdownZoomIn,
            .markdownZoomOut,
            .markdownZoomReset,
        ] {
            XCTAssertEqual(action.shortcutContext, .markdownPanel)
            XCTAssertEqual(action.defaultShortcut, .unbound)
            XCTAssertFalse(KeyboardShortcutSettings.settingsVisibleActions.contains(action))
        }

        let markdown = KeyboardShortcutSettings.Action.markdownZoomIn.shortcutContext
        XCTAssertTrue(markdown.isAvailable(focusedBrowserPanel: false, focusedMarkdownPanel: true, rightSidebarFocused: false))
        XCTAssertFalse(markdown.isAvailable(focusedBrowserPanel: false, focusedMarkdownPanel: false, rightSidebarFocused: false))
        XCTAssertFalse(markdown.isAvailable(focusedBrowserPanel: true, focusedMarkdownPanel: false, rightSidebarFocused: false))

        // Markdown zoom and browser zoom share Cmd-=/-/0 but are mutually
        // exclusive (a panel can't be both), so they must NOT be treated as
        // conflicting bindings.
        let browser = KeyboardShortcutSettings.Action.browserZoomIn.shortcutContext
        XCTAssertFalse(markdown.overlaps(browser))
        XCTAssertTrue(markdown.overlaps(markdown))

        // A focused markdown viewer is also a non-browser panel, so those two
        // contexts CAN be active together and must be treated as overlapping.
        let nonBrowser = KeyboardShortcutSettings.Action.renameTab.shortcutContext
        XCTAssertEqual(nonBrowser, .nonBrowserPanel)
        XCTAssertTrue(markdown.overlaps(nonBrowser))
        XCTAssertTrue(nonBrowser.overlaps(markdown))
    }

    // Regression: on European layouts (German QWERTZ, French AZERTY, Nordic, ...)
    // "+" and "-" are dedicated keys typed WITHOUT Shift, so the event reports
    // character "+"/"-" with no Shift flag and a keyCode that is not the US
    // kVK_ANSI_Equal (24) / kVK_ANSI_Minus (27). The Cmd-=/Cmd-- zoom chords must
    // still match from those keys. See https://github.com/manaflow-ai/cmux/pull/5163.
    func testMarkdownZoomMatchesDedicatedPlusMinusKeysOnNonUSLayout() {
        // German QWERTZ: dedicated "+" key sits at the US RightBracket position
        // (keyCode 30) and produces "+" with no Shift; "-" sits at the US Slash
        // position (keyCode 44) and produces "-" with no Shift.
        let zoomIn = StoredShortcut(key: "=", command: true, shift: false, option: false, control: false)
        XCTAssertTrue(
            zoomIn.matches(
                keyCode: 30,
                modifierFlags: [.command],
                eventCharacter: "+",
                layoutCharacterProvider: { _, _ in "+" }
            ),
            "Cmd and the dedicated + key should zoom markdown in on non-US layouts"
        )

        let zoomOut = StoredShortcut(key: "-", command: true, shift: false, option: false, control: false)
        XCTAssertTrue(
            zoomOut.matches(
                keyCode: 44,
                modifierFlags: [.command],
                eventCharacter: "-",
                layoutCharacterProvider: { _, _ in "-" }
            ),
            "Cmd and the dedicated - key should zoom markdown out on non-US layouts"
        )
    }

    func testBrowserZoomMatchesDedicatedPlusMinusKeysOnNonUSLayout() {
        let zoomIn = StoredShortcut(key: "=", command: true, shift: false, option: false, control: false)
        XCTAssertTrue(
            zoomIn.matches(
                keyCode: 30,
                modifierFlags: [.command],
                eventCharacter: "+",
                layoutCharacterProvider: { _, _ in "+" }
            ),
            "Cmd and the dedicated + key should zoom the browser in on non-US layouts"
        )

        let zoomOut = StoredShortcut(key: "-", command: true, shift: false, option: false, control: false)
        XCTAssertTrue(
            zoomOut.matches(
                keyCode: 44,
                modifierFlags: [.command],
                eventCharacter: "-",
                layoutCharacterProvider: { _, _ in "-" }
            ),
            "Cmd and the dedicated - key should zoom the browser out on non-US layouts"
        )
    }

    // The "_" -> "-" normalization was also moved out of the Shift gate, so a
    // bare "_" (no Shift) from a layout where "_" is a dedicated key must match
    // the "-" zoom-out chord. Without this, a future refactor could re-gate "_"
    // behind Shift with no failing test to catch it.
    func testZoomOutMatchesBareUnderscoreOnNonUSLayout() {
        let markdownZoomOut = StoredShortcut(key: "-", command: true, shift: false, option: false, control: false)
        XCTAssertTrue(
            markdownZoomOut.matches(
                keyCode: 27,
                modifierFlags: [.command],
                eventCharacter: "_",
                layoutCharacterProvider: { _, _ in "_" }
            ),
            "Cmd and a dedicated _ key should zoom markdown out (\"_\" normalizes to \"-\")"
        )

        let browserZoomOut = StoredShortcut(key: "-", command: true, shift: false, option: false, control: false)
        XCTAssertTrue(
            browserZoomOut.matches(
                keyCode: 27,
                modifierFlags: [.command],
                eventCharacter: "_",
                layoutCharacterProvider: { _, _ in "_" }
            ),
            "Cmd and a dedicated _ key should zoom the browser out (\"_\" normalizes to \"-\")"
        )
    }

    func testZoomInDoesNotMatchUnrelatedKeyOnNonUSLayout() {
        // Guard: the layout-aware "+" handling must not make Cmd-= match keys that
        // legitimately produce other characters (e.g. a bare letter key).
        let zoomIn = StoredShortcut(key: "=", command: true, shift: false, option: false, control: false)
        XCTAssertFalse(
            zoomIn.matches(
                keyCode: 45,
                modifierFlags: [.command],
                eventCharacter: "n",
                layoutCharacterProvider: { _, _ in "n" }
            )
        )
    }

    func testFocusHistoryMenuShortcutsSuppressDuplicateBrowserHistoryKeys() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("uniconnect.json", isDirectory: false)
        try writeSettingsFile("{}", to: settingsFileURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let focusBack = KeyboardShortcutSettings.shortcut(for: .focusHistoryBack)
        let focusForward = KeyboardShortcutSettings.shortcut(for: .focusHistoryForward)

        XCTAssertEqual(focusBack, KeyboardShortcutSettings.shortcut(for: .browserBack))
        XCTAssertEqual(focusForward, KeyboardShortcutSettings.shortcut(for: .browserForward))
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .focusHistoryBack), focusBack)
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .focusHistoryForward), focusForward)
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .browserBack), .unbound)
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .browserForward), .unbound)

        KeyboardShortcutSettings.clearShortcut(for: .focusHistoryBack)
        KeyboardShortcutSettings.clearShortcut(for: .focusHistoryForward)

        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .browserBack), KeyboardShortcutSettings.shortcut(for: .browserBack))
        XCTAssertEqual(KeyboardShortcutSettings.menuShortcut(for: .browserForward), KeyboardShortcutSettings.shortcut(for: .browserForward))
    }

    func testFocusHistoryTitlebarHintUsesConfiguredShortcutAndCanBeUnbound() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let directoryURL = try makeTemporaryDirectory()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let settingsFileURL = directoryURL.appendingPathComponent("uniconnect.json", isDirectory: false)
        try writeSettingsFile("{}", to: settingsFileURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()

        let remappedShortcut = StoredShortcut(key: "b", command: true, shift: true, option: false, control: false)
        KeyboardShortcutSettings.setShortcut(remappedShortcut, for: .focusHistoryBack)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .focusHistoryBack), remappedShortcut)
        XCTAssertTrue(
            titlebarShortcutHintShouldShow(
                shortcut: KeyboardShortcutSettings.shortcut(for: .focusHistoryBack),
                alwaysShowShortcutHints: false,
                modifierPressed: true
            )
        )
        XCTAssertTrue(KeyboardShortcutSettings.Action.focusHistoryBack.tooltip("Focus Back").contains(remappedShortcut.displayString))

        KeyboardShortcutSettings.clearShortcut(for: .focusHistoryBack)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .focusHistoryBack), .unbound)
        XCTAssertFalse(
            titlebarShortcutHintShouldShow(
                shortcut: KeyboardShortcutSettings.shortcut(for: .focusHistoryBack),
                alwaysShowShortcutHints: false,
                modifierPressed: true
            )
        )
    }

    func testShortcutSettingsFilePreservesConfiguredShortcutWithoutGlobalConflictLookup() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("uniconnect.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newWindow": "cmd+n"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .newWindow),
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        )
    }

    func testShortcutSettingsFilePreservesUnboundShortcutWithoutGlobalConflictLookup() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("uniconnect.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newWindow": "none"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(store.override(for: .newWindow), StoredShortcut.unbound)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shortcut-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
