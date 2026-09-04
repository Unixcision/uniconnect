import Foundation

extension ShortcutAction {
    /// The factory-default ``ShortcutStroke`` for this action.
    ///
    /// Mirrors the table in
    /// `Sources/KeyboardShortcutSettings.swift` so the package's
    /// settings UI can show "(default: ⌘N)" instead of "(default)"
    /// next to unbound rows, and so the Reset action in the Settings
    /// UI can restore a row by writing the default stroke through
    /// the JSON store.
    public var defaultStroke: ShortcutStroke? {
        switch self {
        case .openSettings: return ShortcutStroke(key: ",", command: true)
        case .reloadConfiguration: return ShortcutStroke(key: ",", command: true, shift: true)
        case .showHideAllWindows: return ShortcutStroke(key: ".", command: true, option: true, control: true)
        case .globalSearch: return ShortcutStroke(key: "f", command: true, option: true)
        case .newWindow: return nil
        case .closeWindow: return nil
        case .toggleFullScreen: return ShortcutStroke(key: "f", command: true, control: true)
        case .lockApp: return ShortcutStroke(key: "l", command: true, control: true)
        case .persistNow: return ShortcutStroke(key: "s", command: true)
        case .reconnectDroppedWindows: return ShortcutStroke(key: "r", command: true, control: true)
        case .reconnectFocusedSSHWindow: return ShortcutStroke(key: "r", command: true)
        case .updateClaudeInWindow: return ShortcutStroke(key: "u", command: true, control: true)
        case .updateClaudeInBox, .updateClaudeEverywhere: return nil
        case .quit: return ShortcutStroke(key: "q", command: true)
        case .toggleSidebar: return ShortcutStroke(key: "b", command: true, option: true)
        case .newTab: return ShortcutStroke(key: "n", command: true)
        case .openFolder: return nil
        case .reopenPreviousSession: return nil
        case .goToWorkspace: return ShortcutStroke(key: "p", command: true)
        case .commandPalette: return ShortcutStroke(key: "p", command: true, shift: true)
        case .commandPaletteNext: return ShortcutStroke(key: "n", control: true)
        case .commandPalettePrevious: return ShortcutStroke(key: "p", control: true)
        case .sendFeedback: return nil
        case .showNotifications: return ShortcutStroke(key: "i", command: true)
        case .jumpToUnread: return ShortcutStroke(key: "u", command: true, shift: true)
        case .toggleUnread: return ShortcutStroke(key: "u", command: true, option: true)
        case .markOldestUnreadAndJumpNext: return nil
        case .focusRightSidebar: return nil
        case .switchRightSidebarToFiles: return nil
        case .switchRightSidebarToFind: return nil
        case .switchRightSidebarToSessions: return nil
        case .switchRightSidebarToFeed: return nil
        case .switchRightSidebarToDock: return nil
        case .triggerFlash: return ShortcutStroke(key: "h", command: true, shift: true)
        case .nextSidebarTab: return ShortcutStroke(key: "]", command: true, control: true)
        case .prevSidebarTab: return ShortcutStroke(key: "[", command: true, control: true)
        case .focusHistoryBack: return nil
        case .focusHistoryForward: return nil
        case .renameTab: return nil
        case .renameWorkspace: return ShortcutStroke(key: "r", command: true, shift: true)
        case .editWorkspaceDescription: return nil
        case .closeTab: return ShortcutStroke(key: "w", command: true)
        case .closeOtherTabsInPane: return ShortcutStroke(key: "t", command: true, option: true)
        case .closeWorkspace: return ShortcutStroke(key: "w", command: true, shift: true)
        case .reopenClosedBrowserPanel: return ShortcutStroke(key: "t", command: true, shift: true)
        case .focusLeft: return ShortcutStroke(key: "←", command: true, option: true)
        case .focusRight: return ShortcutStroke(key: "→", command: true, option: true)
        case .focusUp: return ShortcutStroke(key: "↑", command: true, option: true)
        case .focusDown: return ShortcutStroke(key: "↓", command: true, option: true)
        case .splitRight: return ShortcutStroke(key: "d", command: true)
        case .splitDown: return ShortcutStroke(key: "d", command: true, shift: true)
        case .toggleSplitZoom: return ShortcutStroke(key: "\r", command: true, shift: true)
        case .equalizeSplits: return ShortcutStroke(key: "=", command: true, control: true)
        case .splitBrowserRight: return nil
        case .splitBrowserDown: return nil
        case .nextSurface: return ShortcutStroke(key: "]", command: true, shift: true)
        case .prevSurface: return ShortcutStroke(key: "[", command: true, shift: true)
        case .selectSurfaceByNumber: return ShortcutStroke(key: "1", control: true)
        case .selectWorkspaceByNumber: return ShortcutStroke(key: "1", command: true)
        case .newSurface: return ShortcutStroke(key: "t", command: true)
        case .toggleTerminalCopyMode: return ShortcutStroke(key: "m", command: true, shift: true)
        case .terminalFontSizeIncrease: return ShortcutStroke(key: "=", command: true)
        case .terminalFontSizeDecrease: return ShortcutStroke(key: "-", command: true)
        case .terminalFontSizeReset: return ShortcutStroke(key: "0", command: true)
        case .focusTextBoxInput: return ShortcutStroke(key: "a", command: true, shift: true)
        case .attachTextBoxFile: return ShortcutStroke(key: "a", command: true, shift: true, option: true)
        case .toggleRightSidebar: return nil
        case .openDiffViewer: return nil
        case .saveFilePreview: return nil
        case .openBrowser: return nil
        case .focusBrowserAddressBar: return nil
        case .browserBack: return nil
        case .browserForward: return nil
        case .browserReload: return nil
        case .browserZoomIn: return nil
        case .browserZoomOut: return nil
        case .browserZoomReset: return nil
        case .markdownZoomIn: return nil
        case .markdownZoomOut: return nil
        case .markdownZoomReset: return nil
        case .find: return ShortcutStroke(key: "f", command: true)
        case .findInDirectory: return nil
        case .findNext: return ShortcutStroke(key: "g", command: true)
        case .findPrevious: return ShortcutStroke(key: "g", command: true, option: true)
        case .hideFind: return ShortcutStroke(key: "f", command: true, shift: true, option: true)
        case .useSelectionForFind: return ShortcutStroke(key: "e", command: true)
        case .toggleBrowserDeveloperTools: return nil
        case .showBrowserJavaScriptConsole: return nil
        case .toggleBrowserFocusMode: return nil
        case .toggleReactGrab: return nil
        }
    }
}
