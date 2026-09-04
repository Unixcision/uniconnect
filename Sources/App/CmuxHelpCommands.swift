import AppKit
import SwiftUI

extension cmuxApp {
    @CommandsBuilder
    var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            helpResourceButton(.manual)
            helpResourceButton(.menusAndShortcuts)

            Divider()

            Button {
                openKeyboardShortcutsFromHelpMenu()
            } label: {
                Label(
                    String(localized: "menu.help.keyboardShortcutsSettings", defaultValue: "Keyboard Shortcuts…"),
                    systemImage: "keyboard"
                )
            }

            Divider()

            helpResourceButton(.githubIssues)
        }
    }

    private func helpResourceButton(_ resource: CmuxHelpResource) -> some View {
        Button {
            NSWorkspace.shared.open(resource.url)
        } label: {
            Label(resource.title, systemImage: resource.systemImage)
        }
    }

    private func openKeyboardShortcutsFromHelpMenu() {
        if let appDelegate = AppDelegate.shared {
            appDelegate.openPreferencesWindow(
                debugSource: "helpMenu.keyboardShortcuts",
                navigationTarget: .keyboardShortcuts
            )
        } else {
            AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
        }
    }

}
