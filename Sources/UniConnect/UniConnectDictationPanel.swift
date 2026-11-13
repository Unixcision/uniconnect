import AppKit

/// A floating, borderless panel for «Dictado» that never activates UniConnect by itself.
///
/// It floats over UniConnect's windows (also in full screen), hides while UniConnect is not the
/// active app and stays out of the window cycle and the Window menu. The button's panel never
/// takes the keyboard; the box's takes it only when a text field is clicked, so pressing «Grabar»
/// leaves the terminal focused. The box is a real small window: it is dragged by its header (or
/// any empty part), resized by its edges, and has no title bar or window buttons of its own.
@MainActor
final class UniConnectDictationPanel: NSPanel {
    private let acceptsKey: Bool
    /// Escape while the panel has the keyboard.
    var onCancel: (() -> Void)?

    /// - Parameters:
    ///   - acceptsKey: Whether a text field inside may take the keyboard.
    ///   - windowShadow: Whether AppKit draws the window's shadow; the round button draws its
    ///     own, because a window shadow follows the window's rectangle while it animates.
    ///   - movable: A box the user drags and resizes (hidden title bar, resizable edges), rather
    ///     than a borderless drawing placed by code.
    init(acceptsKey: Bool, windowShadow: Bool = true, movable: Bool = false) {
        self.acceptsKey = acceptsKey
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 52, height: 52),
            styleMask: movable
                ? [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel]
                : [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        if movable {
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
            isMovableByWindowBackground = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                standardWindowButton(button)?.isHidden = true
            }
        } else {
            isOpaque = false
            backgroundColor = .clear
        }
        hasShadow = windowShadow
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
