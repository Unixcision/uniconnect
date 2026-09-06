import AppKit
import CmuxSettings
import CmuxSettingsUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct NativeSettingsPresentationTests {
    @Test("La apertura registrada tiene prioridad sobre un enlace antiguo a una escena")
    func nativeOpenerTakesPrecedenceOverLegacyScene() {
        SettingsWindowPresenter.resetForTests()
        defer { SettingsWindowPresenter.resetForTests() }
        var nativeOpens = 0
        var legacyOpens = 0
        SettingsWindowPresenter.configure(openWindow: { nativeOpens += 1 })
        SettingsWindowPresenter.show(
            navigationTarget: .browserImport,
            openWindowOverride: { legacyOpens += 1 }
        )
        #expect(nativeOpens == 1)
        #expect(legacyOpens == 0)
    }

    @Test("Ajustes abre sin montar la escena bootstrap y reutiliza la ventana al cerrar")
    func opensWithoutBootstrapScene() throws {
        _ = NSApplication.shared
        SettingsWindowPresenter.resetForTests()
        let suite = "NativeSettingsPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let runtime = SettingsRuntime(
            catalog: SettingCatalog(),
            userDefaultsStore: UserDefaultsSettingsStore(defaults: defaults),
            jsonStore: JSONConfigStore(fileURL: directory.appendingPathComponent("uniconnect.json")),
            secretStore: SecretFileStore(baseDirectory: directory),
            errorLog: SettingsErrorLog(),
            privateNetworkAccessAvailable: true
        )
        let delegate = AppDelegate()
        delegate.settingsRuntime = runtime
        defer {
            for window in NSApp.windows where window.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier {
                window.orderOut(nil)
                // AppKit can retain a closed window until its autorelease pool
                // drains. It must not act as the next test's settings window.
                window.identifier = nil
            }
            delegate.settingsRuntime = nil
            SettingsWindowPresenter.resetForTests()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        // Same entrypoint as the menu/shortcut, but no SwiftUI App or scene
        // onAppear has run. Restored AppKit terminal windows follow this path.
        delegate.openPreferencesWindow(debugSource: "test.withoutBootstrap", navigationTarget: .mobile)
        let window = try #require(NSApp.windows.first {
            $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier
        }, "La acción no puede limitarse a encolar un openWindow sin escena")
        #expect(window.isVisible)
        #expect(window.contentViewController != nil)
        #expect(window.parent == nil)
        #expect(window.level == .normal)
        window.close()
        #expect(!window.isVisible)

        delegate.openPreferencesWindow(debugSource: "test.reopen")
        #expect(window.isVisible)
        #expect(NSApp.windows.filter {
            $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier
        }.count == 1)
    }
}
