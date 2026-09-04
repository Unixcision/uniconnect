import Foundation
import Testing
@testable import CmuxSettings

@Suite("SettingCatalog")
struct SettingCatalogTests {
    @Test func appLanguagesCoverEveryShippedCatalogAndPreserveVietnameseCompatibility() {
        let shipped: Set<AppLanguage> = [
            .en, .ar, .bs, .zhHans, .zhHant, .da, .de, .es, .fr, .it,
            .ja, .km, .ko, .nb, .pl, .ptBR, .ru, .th, .tr, .uk,
        ]

        #expect(shipped.count == 20)
        #expect(shipped.isSubset(of: Set(AppLanguage.allCases)))
        #expect(AppLanguage(rawValue: "vi") == .vi)
    }

    @Test func eachKeyHasUniqueId() {
        let ids = SettingCatalog().all.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test func userDefaultsStorageKeysAreUniqueOrExplicitAliases() {
        let keys = SettingCatalog().all.compactMap { entry -> String? in
            if case let .userDefaults(key, _, _) = entry.kind { return key }
            return nil
        }
        let duplicateGroups = Dictionary(grouping: keys, by: { $0 })
            .filter { $0.value.count > 1 }
        let expectedAliases: Set<String> = [
            "ampHooksEnabled",
            "claudeCodeCustomClaudePath",
            "claudeCodeHooksEnabled",
            "cursorHooksEnabled",
            "geminiHooksEnabled",
            "kiroHooksEnabled",
            "kiroNotificationLevel",
            "ripgrepCustomBinaryPath",
            "sidebarActiveTabIndicatorStyle",
            "sidebarNotificationBadgeColorHex",
            "sidebarSelectionColorHex",
            "suppressSubagentNotifications",
        ]

        // The automation/integrations and sidebar/workspace-colors namespaces are
        // intentional API aliases backed by one UserDefaults value. Everything
        // else must retain one-to-one storage ownership.
        #expect(Set(duplicateGroups.keys) == expectedAliases)
        #expect(duplicateGroups.values.allSatisfy { $0.count == 2 })
    }

    @Test func jsonBackedKeysUseTheirIdAsPath() {
        for entry in SettingCatalog().all where entry.kind == .jsonConfig {
            #expect(!entry.id.isEmpty)
            #expect(entry.id.contains("."))
        }
    }

    @Test func allReachesEverySection() {
        // Sanity check: the recursive Mirror walk picks up keys from every
        // nested section. Concretely, both `app.appearance` and
        // `automation.socketPassword` must appear in `all`.
        let ids = Set(SettingCatalog().all.map(\.id))
        #expect(ids.contains("app.appearance"))
        #expect(ids.contains("mobile.iOSPairingHost.enabled"))
        #expect(ids.contains("automation.socketControlMode"))
        #expect(ids.contains("automation.socketPassword"))
    }

    @Test func keyIdsMatchTheirSectionPrefix() {
        // Each key's dotted id must start with its section's prefix; this is
        // the convention that lets the JSON store use `id` as the JSON path.
        let catalog = SettingCatalog()
        for key in catalog.app.all { #expect(key.id.hasPrefix("app.")) }
        for key in catalog.mobile.all { #expect(key.id.hasPrefix("mobile.")) }
        for key in catalog.automation.all { #expect(key.id.hasPrefix("automation.")) }
    }
}
