import SwiftUI

/// Uses AppKit target/action rather than SwiftUI's opaque sender while the app is locked.
struct UniConnectLockActionButton: NSViewRepresentable {
    let title: String
    var prominent = false
    let action: () -> Void

    func makeNSView(context: Context) -> UniConnectLockButton {
        UniConnectLockButton(title: title, prominent: prominent, action: action)
    }

    func updateNSView(_ button: UniConnectLockButton, context: Context) {
        button.title = title
        button.onPress = action
    }
}
