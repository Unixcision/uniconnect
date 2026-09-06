import CmuxSettingsUI
import SwiftUI

/// Native hosting has no SceneStorage. Keep navigation in the retained view,
/// and resolve appearance live just like the main window.
struct SettingsWindowContent: View {
    let runtime: SettingsRuntime
    @State private var selectedSection = "account"
    @State private var selectedSidebarEntry = "section:account"
    @AppStorage(AppearanceSettings.appearanceModeKey)
    private var appearanceMode = AppearanceSettings.defaultMode.rawValue

    init(runtime: SettingsRuntime, initialTarget: SettingsNavigationTarget?) {
        self.runtime = runtime
        let section = initialTarget?.rawValue ?? "account"
        _selectedSection = State(initialValue: section)
        _selectedSidebarEntry = State(initialValue: "section:\(section)")
    }

    var body: some View {
        SettingsWindowRoot(
            runtime: runtime,
            selectedSection: $selectedSection,
            selectedSidebarEntry: $selectedSidebarEntry
        )
        .settingsRuntime(runtime)
        .cmuxAppearanceColorScheme(appearanceMode)
    }
}
