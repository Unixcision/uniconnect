import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite struct SettingsRuntimeHostedServicesTests {
    @Test func hostedServicesDefaultToUnavailable() {
        let runtime = makeRuntime()

        #expect(runtime.hostedServicesAvailable == false)
    }

    @Test func hostMustExplicitlyMarkHostedServicesAvailable() {
        let runtime = makeRuntime(hostedServicesAvailable: true)

        #expect(runtime.hostedServicesAvailable == true)
    }

    private func makeRuntime(hostedServicesAvailable: Bool = false) -> SettingsRuntime {
        let identifier = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsRuntimeHostedServicesTests-\(identifier)", isDirectory: true)
        return SettingsRuntime(
            catalog: SettingCatalog(),
            userDefaultsStore: UserDefaultsSettingsStore(
                defaults: UserDefaults(suiteName: "SettingsRuntimeHostedServicesTests.\(identifier)")!
            ),
            jsonStore: JSONConfigStore(fileURL: directory.appendingPathComponent("uniconnect.json")),
            secretStore: SecretFileStore(baseDirectory: directory),
            errorLog: SettingsErrorLog(),
            hostedServicesAvailable: hostedServicesAvailable
        )
    }
}
