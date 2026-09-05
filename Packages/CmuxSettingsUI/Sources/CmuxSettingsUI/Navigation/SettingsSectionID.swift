import Foundation

/// Top-level navigation targets for the settings window.
///
/// The cmux app exposes a fixed set of section panes. Each section gets
/// its own SwiftUI view in `Sections/`; the sidebar lists them in
/// declaration order, the search index filters across all of them.
///
/// Adding a section means: add a case here, add its title and icon in
/// the `SettingsSectionID` extension below, and add a view file in
/// `Sections/`.
public enum SettingsSectionID: String, CaseIterable, Identifiable, Sendable, Hashable {
    case account
    case app
    case terminal
    case textBox
    /// Mobile pairing and sync settings.
    case mobile
    case sidebarAppearance
    case betaFeatures
    case automation
    case browser
    case browserImport
    case globalHotkey
    case keyboardShortcuts
    case workspaceColors
    case settingsJSON
    case reset

    public var id: Self { self }

    /// User-facing section title shown in the sidebar.
    public var title: String {
        switch self {
        case .account: return String(localized: "settings.section.account", defaultValue: "Cuenta")
        case .app: return String(localized: "settings.section.app", defaultValue: "Aplicación")
        case .terminal: return String(localized: "settings.section.terminal", defaultValue: "Terminal")
        case .textBox: return String(localized: "settings.section.textBox", defaultValue: "Cuadro de texto (beta)")
        case .mobile: return String(localized: "settings.section.mobile", defaultValue: "Acceso remoto")
        case .sidebarAppearance: return String(localized: "settings.section.sidebarAppearance", defaultValue: "Barra lateral")
        case .betaFeatures: return String(localized: "settings.section.betaFeatures", defaultValue: "Funciones beta")
        case .automation: return String(localized: "settings.section.automation", defaultValue: "Automatización")
        case .browser: return String(localized: "settings.section.browser", defaultValue: "Navegador")
        case .browserImport: return String(localized: "settings.section.browserImport", defaultValue: "Importar datos del navegador")
        case .globalHotkey: return String(localized: "settings.section.globalHotkey", defaultValue: "Atajo global")
        case .keyboardShortcuts: return String(localized: "settings.section.keyboardShortcuts", defaultValue: "Atajos de teclado")
        case .workspaceColors: return String(localized: "settings.section.workspaceColors", defaultValue: "Colores de espacios de trabajo")
        case .settingsJSON: return String(localized: "settings.section.settingsJSON", defaultValue: "uniconnect.json")
        case .reset: return String(localized: "settings.section.reset", defaultValue: "Restablecer")
        }
    }

    /// SF Symbol shown alongside the title in the sidebar.
    public var symbolName: String {
        switch self {
        case .account: return "person.crop.circle"
        case .app: return "gearshape"
        case .terminal: return "terminal"
        case .textBox: return "textformat"
        case .mobile: return "iphone"
        case .sidebarAppearance: return "sidebar.left"
        case .betaFeatures: return "exclamationmark.triangle"
        case .automation: return "wand.and.sparkles"
        case .browser: return "globe"
        case .browserImport: return "square.and.arrow.down"
        case .globalHotkey: return "keyboard.badge.ellipsis"
        case .keyboardShortcuts: return "keyboard"
        case .workspaceColors: return "paintpalette"
        case .settingsJSON: return "doc.text"
        case .reset: return "arrow.counterclockwise"
        }
    }

    /// Space-separated keywords used by the settings search index. Each
    /// section can advertise additional terms here so users find sections
    /// by capability rather than only by title.
    public var searchKeywords: String {
        switch self {
        case .account: return "sign in team sync user profile"
        case .app: return "appearance language workspace notifications menu bar telemetry"
        case .terminal: return "scrollbar copy on select agent resume hibernation"
        case .textBox: return "textbox text box rich input prompt default new terminal workspace split tab focus show beta"
        case .mobile: return "android móvil pixel tailscale ip acceso remoto autorizacion sincronización mobile"
        case .sidebarAppearance: return "sidebar details branches material terminal background"
        case .betaFeatures: return "beta experimental unstable feed dock right sidebar"
        case .automation: return "socket integrations hooks ports claude cursor gemini"
        case .browser: return "search engine links history theme"
        case .browserImport: return "browser import bookmarks history cookies"
        case .globalHotkey: return "system wide shortcut"
        case .keyboardShortcuts: return "keybindings commands chords"
        case .workspaceColors: return "palette tabs indicator"
        case .settingsJSON: return "config file preferences editor schema jsonc reload"
        case .reset: return "defaults reset"
        }
    }
}
