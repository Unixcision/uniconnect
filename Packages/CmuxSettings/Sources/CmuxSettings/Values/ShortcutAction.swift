import Foundation

/// The stable, user-customisable shortcut actions cmux exposes.
///
/// Each case is a one-line identifier that maps to one user-facing
/// behavior. The set is intentionally flat (rather than nested by
/// category) so the JSON config representation stays readable
/// (`"shortcuts.bindings": { "openSettings": "cmd+,", ... }`).
///
/// Display names + group categorization are metadata derived from the
/// enum case in extensions below; the raw value is the stable
/// identifier persisted in uniconnect.json.
public enum ShortcutAction: String, CaseIterable, Sendable, Hashable, SettingCodable {
    // MARK: App
    case openSettings
    case reloadConfiguration
    case showHideAllWindows
    case globalSearch
    case newWindow
    case closeWindow
    case toggleFullScreen
    /// Locks UniConnect while leaving terminal and remote sessions running.
    case lockApp
    /// Writes the current UniConnect session snapshot immediately.
    case persistNow
    /// Immediately reconnects every open UniConnect SSH/tmux window, including hung connections.
    case reconnectDroppedWindows
    /// Immediately reconnects the focused UniConnect SSH/tmux window.
    case reconnectFocusedSSHWindow
    /// Updates Claude for the focused UniConnect window.
    case updateClaudeInWindow
    /// Updates Claude for the selected UniConnect box.
    case updateClaudeInBox
    /// Updates Claude across every open UniConnect box.
    case updateClaudeEverywhere
    case quit

    // MARK: Workspace
    case toggleSidebar
    case newTab
    case openFolder
    case reopenPreviousSession
    case goToWorkspace
    case commandPalette
    case commandPaletteNext
    case commandPalettePrevious
    case sendFeedback
    case showNotifications
    case jumpToUnread
    case toggleUnread
    case markOldestUnreadAndJumpNext
    case focusRightSidebar
    case switchRightSidebarToFiles
    case switchRightSidebarToFind
    case switchRightSidebarToSessions
    case switchRightSidebarToFeed
    case switchRightSidebarToDock
    case triggerFlash

    // MARK: Navigation
    case nextSurface
    case prevSurface
    case selectSurfaceByNumber
    case nextSidebarTab
    case prevSidebarTab
    case focusHistoryBack
    case focusHistoryForward
    case selectWorkspaceByNumber
    case renameTab
    case renameWorkspace
    case editWorkspaceDescription
    case closeTab
    case closeOtherTabsInPane
    case closeWorkspace
    case reopenClosedBrowserPanel
    case newSurface
    case toggleTerminalCopyMode
    /// Increases the font size of the focused terminal.
    case terminalFontSizeIncrease
    /// Decreases the font size of the focused terminal.
    case terminalFontSizeDecrease
    /// Restores the focused terminal's default font size.
    case terminalFontSizeReset
    case focusTextBoxInput
    case attachTextBoxFile

    // MARK: Panes
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case splitRight
    case splitDown
    case toggleSplitZoom
    case equalizeSplits
    case splitBrowserRight
    case splitBrowserDown
    case toggleRightSidebar = "toggleFileExplorer"

    // MARK: Browser & Find
    case openDiffViewer
    case saveFilePreview
    case openBrowser
    case focusBrowserAddressBar
    case browserBack
    case browserForward
    case browserReload
    case browserZoomIn
    case browserZoomOut
    case browserZoomReset
    case markdownZoomIn
    case markdownZoomOut
    case markdownZoomReset
    case find
    case findInDirectory
    case findNext
    case findPrevious
    case hideFind
    case useSelectionForFind
    case toggleBrowserDeveloperTools
    case showBrowserJavaScriptConsole
    case toggleBrowserFocusMode
    case toggleReactGrab
}

extension ShortcutAction {
    /// Logical grouping used for sectioning the shortcuts pane.
    public enum Group: String, CaseIterable, Sendable, Hashable {
        case app
        case workspace
        case navigation
        case panes
        case browser

        public var title: String {
            switch self {
            case .app: return "App"
            case .workspace: return "Workspace"
            case .navigation: return "Navigation"
            case .panes: return "Panes"
            case .browser: return "Browser & Find"
            }
        }
    }

    /// Which group this action belongs to in the settings pane.
    public var group: Group {
        switch self {
        case .openSettings, .reloadConfiguration, .showHideAllWindows, .globalSearch,
             .newWindow, .closeWindow, .toggleFullScreen, .lockApp, .persistNow,
             .reconnectDroppedWindows, .reconnectFocusedSSHWindow,
             .updateClaudeInWindow, .updateClaudeInBox,
             .updateClaudeEverywhere, .quit:
            return .app
        case .toggleSidebar, .newTab, .openFolder, .reopenPreviousSession, .goToWorkspace,
             .commandPalette, .commandPaletteNext, .commandPalettePrevious, .sendFeedback,
             .showNotifications, .jumpToUnread, .toggleUnread, .markOldestUnreadAndJumpNext,
             .focusRightSidebar, .switchRightSidebarToFiles, .switchRightSidebarToFind,
             .switchRightSidebarToSessions, .switchRightSidebarToFeed,
             .switchRightSidebarToDock, .triggerFlash:
            return .workspace
        case .nextSurface, .prevSurface, .selectSurfaceByNumber, .nextSidebarTab,
             .prevSidebarTab, .focusHistoryBack, .focusHistoryForward,
             .selectWorkspaceByNumber, .renameTab, .renameWorkspace,
             .editWorkspaceDescription, .closeTab, .closeOtherTabsInPane, .closeWorkspace,
             .reopenClosedBrowserPanel, .newSurface, .toggleTerminalCopyMode,
             .terminalFontSizeIncrease, .terminalFontSizeDecrease, .terminalFontSizeReset,
             .focusTextBoxInput, .attachTextBoxFile:
            return .navigation
        case .focusLeft, .focusRight, .focusUp, .focusDown, .splitRight, .splitDown,
             .toggleSplitZoom, .equalizeSplits, .splitBrowserRight, .splitBrowserDown,
             .toggleRightSidebar:
            return .panes
        case .openDiffViewer, .saveFilePreview, .openBrowser, .focusBrowserAddressBar, .browserBack,
             .browserForward, .browserReload, .browserZoomIn, .browserZoomOut,
             .browserZoomReset, .markdownZoomIn, .markdownZoomOut, .markdownZoomReset,
             .find, .findInDirectory, .findNext, .findPrevious,
             .hideFind, .useSelectionForFind, .toggleBrowserDeveloperTools,
             .showBrowserJavaScriptConsole, .toggleBrowserFocusMode, .toggleReactGrab:
            return .browser
        }
    }

    /// User-facing display name shown in the Settings UI.
    public var displayName: String {
        switch self {
        case .openSettings: return "Settings…"
        case .reloadConfiguration: return "Reload Configuration"
        case .showHideAllWindows: return "Show/Hide All Windows"
        case .globalSearch: return "Global Search"
        case .newWindow: return "New Window"
        case .closeWindow: return "Close Window"
        case .toggleFullScreen: return "Toggle Full Screen"
        case .lockApp: return String(localized: "shortcut.lockApp.label", defaultValue: "Lock UniConnect")
        case .persistNow: return String(localized: "shortcut.persistNow.label", defaultValue: "Save Now")
        case .reconnectDroppedWindows:
            return String(
                localized: "uniconnect.reconnect.all.now",
                defaultValue: "Reconnect All SSH Windows"
            )
        case .reconnectFocusedSSHWindow:
            return String(
                localized: "shortcut.reconnectFocusedSSHWindow.label",
                defaultValue: "Reconnect This SSH Window Now"
            )
        case .updateClaudeInWindow: return String(localized: "shortcut.updateClaudeInWindow.label", defaultValue: "Update Claude in This Window")
        case .updateClaudeInBox: return String(localized: "shortcut.updateClaudeInBox.label", defaultValue: "Update Claude in This Box")
        case .updateClaudeEverywhere: return String(localized: "shortcut.updateClaudeEverywhere.label", defaultValue: "Update Claude Everywhere")
        case .quit: return String(localized: "menu.app.quitUniConnect", defaultValue: "Quit UniConnect")
        case .toggleSidebar: return String(localized: "shortcut.toggleLeftSidebar.label", defaultValue: "Compact or Expand Sidebar")
        case .newTab: return String(localized: "shortcut.newWorkspace.label", defaultValue: "New Box…")
        case .openFolder: return "Open Folder"
        case .reopenPreviousSession: return "Restore Previous App Launch"
        case .goToWorkspace: return String(localized: "menu.box.goTo", defaultValue: "Go to Box…")
        case .commandPalette: return "Command Palette…"
        case .commandPaletteNext: return "Command Palette: Next"
        case .commandPalettePrevious: return "Command Palette: Previous"
        case .sendFeedback: return "Send Feedback"
        case .showNotifications: return "Show Notifications"
        case .jumpToUnread: return "Jump to Latest Unread"
        case .toggleUnread: return "Toggle Unread"
        case .markOldestUnreadAndJumpNext: return "Mark as Oldest Unread and Jump to Next Latest Unread"
        case .focusRightSidebar: return "Toggle Right Sidebar Focus"
        case .switchRightSidebarToFiles: return "Show Sidebar Files"
        case .switchRightSidebarToFind: return "Show Sidebar Find"
        case .switchRightSidebarToSessions: return "Show Sidebar Vault"
        case .switchRightSidebarToFeed: return "Show Sidebar Feed"
        case .switchRightSidebarToDock: return "Show Sidebar Dock"
        case .triggerFlash: return "Flash Focused Panel"
        case .nextSurface: return String(localized: "shortcut.nextSurface.label", defaultValue: "Next Window")
        case .prevSurface: return String(localized: "shortcut.previousSurface.label", defaultValue: "Previous Window")
        case .selectSurfaceByNumber: return String(localized: "shortcut.selectSurfaceByNumber.label", defaultValue: "Select Window 1…9")
        case .nextSidebarTab: return String(localized: "shortcut.nextWorkspace.label", defaultValue: "Next Box")
        case .prevSidebarTab: return String(localized: "shortcut.previousWorkspace.label", defaultValue: "Previous Box")
        case .focusHistoryBack: return "Focus Back"
        case .focusHistoryForward: return "Focus Forward"
        case .selectWorkspaceByNumber: return String(localized: "shortcut.selectWorkspaceByNumber.label", defaultValue: "Select Box 1…9")
        case .renameTab: return String(localized: "shortcut.renameTab.label", defaultValue: "Rename Window")
        case .renameWorkspace: return String(localized: "shortcut.renameWorkspace.label", defaultValue: "Rename Box")
        case .editWorkspaceDescription: return "Edit Workspace Description"
        case .closeTab: return String(localized: "menu.file.closeWindowInBox", defaultValue: "Close Window")
        case .closeOtherTabsInPane: return String(localized: "menu.file.closeOtherWindowsInPanel", defaultValue: "Close Other Windows in Panel")
        case .closeWorkspace: return String(localized: "shortcut.closeWorkspace.label", defaultValue: "Close Box")
        case .reopenClosedBrowserPanel: return "Reopen Last Closed"
        case .newSurface: return String(localized: "shortcut.newSurface.label", defaultValue: "New Tab")
        case .toggleTerminalCopyMode: return "Toggle Terminal Copy Mode"
        case .terminalFontSizeIncrease: return String(localized: "shortcut.terminalFontSizeIncrease.label", defaultValue: "Increase Terminal Font Size")
        case .terminalFontSizeDecrease: return String(localized: "shortcut.terminalFontSizeDecrease.label", defaultValue: "Decrease Terminal Font Size")
        case .terminalFontSizeReset: return String(localized: "shortcut.terminalFontSizeReset.label", defaultValue: "Reset Terminal Font Size")
        case .focusTextBoxInput: return "Focus TextBox Input"
        case .attachTextBoxFile: return "Attach File to TextBox Input"
        case .focusLeft: return "Focus Pane Left"
        case .focusRight: return "Focus Pane Right"
        case .focusUp: return "Focus Pane Up"
        case .focusDown: return "Focus Pane Down"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        case .toggleSplitZoom: return "Toggle Pane Zoom"
        case .equalizeSplits: return "Equalize Splits"
        case .splitBrowserRight: return "Split Browser Right"
        case .splitBrowserDown: return "Split Browser Down"
        case .toggleRightSidebar: return "Toggle Right Sidebar"
        case .openDiffViewer: return "Open Diff Viewer"
        case .saveFilePreview: return "Save File Preview"
        case .openBrowser: return "Open Browser"
        case .focusBrowserAddressBar: return "Focus Address Bar"
        case .browserBack: return "Back"
        case .browserForward: return "Forward"
        case .browserReload: return "Reload Page"
        case .browserZoomIn: return "Zoom In"
        case .browserZoomOut: return "Zoom Out"
        case .browserZoomReset: return "Actual Size"
        case .markdownZoomIn: return "Markdown Viewer: Zoom In"
        case .markdownZoomOut: return "Markdown Viewer: Zoom Out"
        case .markdownZoomReset: return "Markdown Viewer: Actual Size"
        case .find: return "Find…"
        case .findInDirectory: return "Find in Directory…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .hideFind: return "Hide Find Bar"
        case .useSelectionForFind: return "Use Selection for Find"
        case .toggleBrowserDeveloperTools: return "Toggle Browser Developer Tools"
        case .showBrowserJavaScriptConsole: return "Show Browser JavaScript Console"
        case .toggleBrowserFocusMode: return "Enter Browser Focus Mode"
        case .toggleReactGrab: return "Toggle React Grab"
        }
    }
}
