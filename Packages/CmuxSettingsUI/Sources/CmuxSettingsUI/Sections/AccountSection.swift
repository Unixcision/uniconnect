import CmuxSettings
import SwiftUI

/// **Account** section — mirrors the legacy in-app section: a single
/// `SettingsCard` containing the identity row (primary email title +
/// display name subtitle + Sign In / Sign Out button, no avatar). The
/// integration toggles (Claude Code, Cursor, Gemini, ripgrep, subagent
/// suppression) live under **Automation** to match legacy ordering.
@MainActor
public struct AccountSection: View {
    private let accountFlow: AccountFlow?
    private let hostedServicesAvailable: Bool

    /// Creates the account section.
    ///
    /// - Parameters:
    ///   - defaultsStore: The shared defaults store; retained in the uniform section API.
    ///   - catalog: The settings catalog; retained in the uniform section API.
    ///   - accountFlow: The host-provided account flow, when configured.
    ///   - hostedServicesAvailable: Whether online account services are safe to use.
    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        accountFlow: AccountFlow?,
        hostedServicesAvailable: Bool = false
    ) {
        // `defaultsStore` and `catalog` are part of the section's shared
        // init shape (every section takes them) but the Account card binds
        // no defaults-backed values, so neither is stored. The identity row
        // is driven entirely by `accountFlow`.
        _ = defaultsStore
        _ = catalog
        self.accountFlow = accountFlow
        self.hostedServicesAvailable = hostedServicesAvailable
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.account", defaultValue: "Account"), section: .account)
            SettingsCard {
                AccountIdentityCard(
                    flow: accountFlow,
                    hostedServicesAvailable: hostedServicesAvailable
                )
            }
            .settingsSearchAnchors(["setting:account:account"])
        }
    }
}
