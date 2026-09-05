import AppKit
import SwiftUI

/// One of the three window controls UniConnect draws itself.
///
/// UniConnect hides AppKit's own traffic lights and renders these in their place.
/// That is the single decision that makes the sidebar chrome tractable: AppKit
/// moves its buttons on its own schedule — nudging them for a sidebar, hiding them
/// in full screen, sliding them back when the menu bar drops — and every one of
/// those moves has to be predicted and worked around by anything sharing their
/// row. Owning the buttons removes the negotiation: one layout serves a window and
/// full screen alike, because nothing repositions behind our back.
enum UniConnectWindowControlKind: CaseIterable, Identifiable {
    case close
    case minimize
    case zoom

    var id: Self { self }

    /// The system's colour for this control on an active window.
    var activeColor: Color {
        switch self {
        case .close: return Color(red: 1.0, green: 0.373, blue: 0.341)
        case .minimize: return Color(red: 0.996, green: 0.737, blue: 0.180)
        case .zoom: return Color(red: 0.157, green: 0.784, blue: 0.251)
        }
    }

    /// SF Symbol revealed while the pointer is over the group.
    var hoverSymbol: String {
        switch self {
        case .close: return "xmark"
        case .minimize: return "minus"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        }
    }

    /// Spoken label for assistive technology.
    var accessibilityLabel: String {
        switch self {
        case .close:
            return String(localized: "window.control.close", defaultValue: "Close")
        case .minimize:
            return String(localized: "window.control.minimize", defaultValue: "Minimize")
        case .zoom:
            return String(
                localized: "command.toggleFullScreen.title",
                defaultValue: "Toggle Full Screen"
            )
        }
    }

    /// Stable identifier for UI tests.
    var accessibilityIdentifier: String {
        switch self {
        case .close: return "uniConnectWindowControl.close"
        case .minimize: return "uniConnectWindowControl.minimize"
        case .zoom: return "uniConnectWindowControl.zoom"
        }
    }

    /// Whether the control does anything for `window` in its current state.
    ///
    /// - Parameter window: The window the control acts on, if it is on screen.
    /// - Returns: `false` when the action is unavailable — minimize in full screen,
    ///   or any control without a window — so it can render greyed like the
    ///   system's own.
    @MainActor
    func isEnabled(for window: NSWindow?) -> Bool {
        guard let window else { return false }
        switch self {
        case .close:
            return window.styleMask.contains(.closable)
        case .minimize:
            return window.styleMask.contains(.miniaturizable)
                && !window.styleMask.contains(.fullScreen)
        case .zoom:
            return window.styleMask.contains(.resizable)
        }
    }

    /// Performs this control's action.
    ///
    /// - Parameter window: The window to act on.
    @MainActor
    func perform(on window: NSWindow?) {
        guard let window, isEnabled(for: window) else { return }
        switch self {
        case .close: window.performClose(nil)
        case .minimize: window.performMiniaturize(nil)
        // AppKit's green traffic light toggles the native full-screen space.
        // `performZoom` only resizes the window and can be a no-op when it is
        // already at its zoomed frame, which made this custom control appear dead.
        case .zoom: window.toggleFullScreen(nil)
        }
    }
}
