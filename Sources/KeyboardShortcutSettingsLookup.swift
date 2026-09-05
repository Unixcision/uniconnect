import Foundation

extension KeyboardShortcutSettings {
    static let focusedSSHReconnectCommandRMigrationKey =
        "shortcutMigration.focusedSSHReconnectCommandR.v1"

    /// Records the default change without mutating a persisted user shortcut.
    ///
    /// Factory shortcuts are computed and are not written to `UserDefaults`. Therefore an
    /// existing `renameTab` value, even when it equals the former Cmd+R default, is an
    /// explicit user binding and must survive the default reassignment.
    static func migrateLegacyRenameCommandRIfNeeded(
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: focusedSSHReconnectCommandRMigrationKey) else { return }
        defaults.set(true, forKey: focusedSSHReconnectCommandRMigrationKey)
    }

    static func shortcutIfBound(for action: Action) -> StoredShortcut? {
        #if DEBUG
        shortcutLookupObserver?(action)
        #endif

        migrateLegacyRenameCommandRIfNeeded()

        if let managedShortcut = settingsFileStore.override(for: action) {
            return managedShortcut.isUnbound ? nil : managedShortcut
        }

        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            let defaultShortcut = action.defaultShortcut
            return defaultShortcut.isUnbound ? nil : defaultShortcut
        }
        return shortcut.isUnbound ? nil : shortcut
    }

    static func shortcut(for action: Action) -> StoredShortcut {
        shortcutIfBound(for: action) ?? .unbound
    }

    static func menuShortcut(for action: Action) -> StoredShortcut {
        guard !KeyboardShortcutRecorderActivity.isAnyRecorderActive else {
            return .unbound
        }

        let shortcut = shortcut(for: action)
        switch action {
        case .browserBack
            where !shortcut.isUnbound && shortcut == KeyboardShortcutSettings.shortcut(for: .focusHistoryBack):
            return .unbound
        case .browserForward
            where !shortcut.isUnbound && shortcut == KeyboardShortcutSettings.shortcut(for: .focusHistoryForward):
            return .unbound
        default:
            return shortcut
        }
    }

    static func isManagedBySettingsFile(_ action: Action) -> Bool {
        settingsFileStore.isManagedByFile(action)
    }

    static func unbindShortcut(for action: Action) {
        setShortcut(.unbound, for: action)
    }

    static func settingsFileManagedSubtitle(for action: Action) -> String? {
        guard isManagedBySettingsFile(action) else { return nil }
        return String(localized: "settings.shortcuts.managedByFile", defaultValue: "Managed in uniconnect.json")
    }

}
