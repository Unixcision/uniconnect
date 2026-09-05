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
        #expect(runtime.privateNetworkAccessAvailable == false)
    }

    @Test func privateNetworkAccessDoesNotEnableCloudAccounts() {
        let runtime = makeRuntime(privateNetworkAccessAvailable: true)

        #expect(runtime.privateNetworkAccessAvailable == true)
        #expect(runtime.hostedServicesAvailable == false)
        #expect(runtime.accountFlow == nil)
    }

    private func makeRuntime(
        hostedServicesAvailable: Bool = false,
        privateNetworkAccessAvailable: Bool = false
    ) -> SettingsRuntime {
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
            hostedServicesAvailable: hostedServicesAvailable,
            privateNetworkAccessAvailable: privateNetworkAccessAvailable
        )
    }
}
