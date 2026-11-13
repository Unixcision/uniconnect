import AppKit
import SwiftUI

/// The floating button and the box of «Dictado», as two panels over UniConnect's windows.
///
/// The button starts at the bottom right of the screen and can be dragged to either edge, at any
/// height; dropped partly past an edge, or with «Esconder en el borde», it tucks itself in as a
/// pill. A click on it records, and the next click stops and opens the box, where the last
/// dictation waits to be pasted, pasted and sent, or copied: stopping never pastes by itself.
/// The box also opens with Option-click, the right-click menu or UniConnect › Dictado por voz…,
/// and by itself when something needs to be read (no microphone, a failure).
/// The box opens beside the button until the user drags or resizes it; from then on it opens
/// where the user left it, until «Colocar la caja junto al botón». Where it is, and whether it is shown at all, is remembered. Both panels hide while
/// UniConnect is locked (the history holds what was said) and while it is not the active app.
@MainActor
final class UniConnectDictationPanelController: NSObject {
    private enum Keys {
        static let visible = "uniconnect.dictation.buttonVisible"
        static let edge = "uniconnect.dictation.edge"
        static let bottomOffset = "uniconnect.dictation.bottomOffset"
        static let docked = "uniconnect.dictation.docked"
        static let boxFrame = "uniconnect.dictation.boxFrame"
    }

    /// Smallest box that still shows the recorder, the last dictation and a few history entries.
    private static let boxMinimumSize = NSSize(width: 360, height: 440)

    private let model: UniConnectDictationModel
    private let state: UniConnectDictationBubbleState
    private let defaults: UserDefaults
    private let lockStates: AsyncStream<Bool>?
    private var bubblePanel: UniConnectDictationPanel?
    private var bubbleHost: UniConnectDictationBubbleHostView?
    private var boxPanel: UniConnectDictationPanel?
    /// `nil` until the lock answered once: nothing is shown before knowing it is unlocked.
    private var isLocked: Bool?
    private var tasks: [Task<Void, Never>] = []
    /// The window that had the keyboard before the box took it, to give it back.
    private weak var keyWindowBeforeBox: NSWindow?
    /// Set while code moves the box, so only the user's moves are remembered.
    private var placingBox = false

    /// Whether the floating button is shown (UniConnect › Dictado por voz… shows it again).
    private(set) var isEnabled: Bool

    /// - Parameters:
    ///   - model: The dictation.
    ///   - defaults: Where the button's place is remembered.
    ///   - lockStates: UniConnect's lock, current value first; `nil` means it never locks.
    init(model: UniConnectDictationModel, defaults: UserDefaults, lockStates: AsyncStream<Bool>?) {
        self.model = model
        self.defaults = defaults
        self.lockStates = lockStates
        self.state = UniConnectDictationBubbleState(layout: Self.storedLayout(in: defaults))
        self.isEnabled = defaults.object(forKey: Keys.visible) as? Bool ?? true
        self.isLocked = lockStates == nil ? false : nil
        super.init()
    }

    /// Starts following the lock, the screens and the app's activation, and shows the button.
    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in
            await self?.model.loadHistory()
        })
        if let lockStates {
            tasks.append(Task { [weak self] in
                for await locked in lockStates {
                    await self?.lockChanged(locked)
                }
            })
        }
        for name in [NSApplication.didChangeScreenParametersNotification, NSApplication.didBecomeActiveNotification] {
            tasks.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    self?.refreshVisibility()
                }
            })
        }
        refreshVisibility()
    }

    /// Opens the box, bringing the button back first if it was hidden or tucked in.
    func openBox() {
        if !isEnabled {
            isEnabled = true
            defaults.set(true, forKey: Keys.visible)
        }
        if state.layout.docked {
            state.layout.docked = false
            storeLayout()
        }
        refreshVisibility()
        guard isLocked == false, let visible = visibleFrame() else { return }
        let panel = boxPanel ?? makeBoxPanel()
        boxPanel = panel
        keyWindowBeforeBox = NSApp.keyWindow
        setBoxFrame(userBoxFrame(in: visible) ?? state.layout.boxFrame(in: visible), animated: false)
        panel.orderFront(nil)
        state.boxOpen = true
    }

    /// Forgets where the user left the box and puts it back beside the button.
    func placeBoxBesideButton() {
        defaults.removeObject(forKey: Keys.boxFrame)
        guard state.boxOpen, let visible = visibleFrame() else { return }
        setBoxFrame(state.layout.boxFrame(in: visible), animated: true)
    }

    /// Where the user left the box, if it still fits on this screen.
    private func userBoxFrame(in visible: CGRect) -> CGRect? {
        guard let stored = defaults.string(forKey: Keys.boxFrame) else { return nil }
        let frame = NSRectFromString(stored)
        guard frame.width >= Self.boxMinimumSize.width, frame.height >= Self.boxMinimumSize.height,
              visible.intersection(frame).width >= 120, visible.intersection(frame).height >= 120 else { return nil }
        return frame
    }

    private func setBoxFrame(_ frame: CGRect, animated: Bool) {
        placingBox = true
        boxPanel?.setFrame(frame, display: true, animate: animated)
        placingBox = false
    }

    /// Closes the box, giving the keyboard back to the window that had it.
    func closeBox() {
        guard let boxPanel, boxPanel.isVisible || state.boxOpen else { return }
        let hadKeyboard = boxPanel.isKeyWindow
        boxPanel.orderOut(nil)
        state.boxOpen = false
        if hadKeyboard {
            (keyWindowBeforeBox ?? NSApp.mainWindow)?.makeKey()
        }
    }

    private func toggleBox() {
        if state.boxOpen {
            closeBox()
        } else {
            openBox()
        }
    }

    /// Tucks the button into its edge as a pill.
    func dock() {
        closeBox()
        state.layout.docked = true
        storeLayout()
        place(animated: true)
    }

    /// Brings the round button back from the pill.
    func undock() {
        state.layout.docked = false
        storeLayout()
        place(animated: true)
    }

    /// Hides the button until UniConnect › Dictado por voz… shows it again.
    func hideButton() {
        closeBox()
        isEnabled = false
        defaults.set(false, forKey: Keys.visible)
        refreshVisibility()
    }

    private func lockChanged(_ locked: Bool) async {
        isLocked = locked
        if locked {
            closeBox()
            refreshVisibility()
            await model.appLocked()
        } else {
            refreshVisibility()
        }
    }

    /// Shows the button when it should be seen, hides both panels otherwise, and puts it in place.
    private func refreshVisibility() {
        guard isEnabled, isLocked == false else {
            closeBox()
            bubblePanel?.orderOut(nil)
            return
        }
        let panel = bubblePanel ?? makeBubblePanel()
        bubblePanel = panel
        place(animated: false)
        // A panel ordered in while another app is in front would float over it; activation shows it.
        if NSApp.isActive {
            panel.orderFront(nil)
        }
    }

    private func place(animated: Bool) {
        guard let visible = visibleFrame() else { return }
        bubbleHost?.toolTip = state.layout.docked
            ? String(localized: "uniconnect.dictation.pill.help", defaultValue: "Dictado: pulsa para sacar el botón")
            : String(localized: "uniconnect.dictation.bubble.help.v3", defaultValue: "Dictado: clic para grabar y otro para parar; el texto te espera en la caja para pegarlo. ⌥-clic o clic derecho: historial y opciones. Arrástralo al borde para esconderlo.")
        bubblePanel?.setFrame(state.layout.frame(in: visible), display: true, animate: animated)
        // A box the user placed stays where it is; otherwise it follows the button.
        if state.boxOpen, userBoxFrame(in: visible) == nil {
            setBoxFrame(state.layout.boxFrame(in: visible), animated: animated)
        }
    }

    /// The screen of the window being used, or the main screen.
    private func visibleFrame() -> CGRect? {
        (NSApp.mainWindow?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
    }

    private func bubbleClicked(_ modifiers: NSEvent.ModifierFlags) {
        if state.layout.docked {
            undock()
        } else if modifiers.contains(.option) {
            toggleBox()
        } else {
            Task { await recordFromBubble() }
        }
    }

    /// One click records without opening anything; the next stops and opens the box, where the
    /// text appears when Whisper is done and waits for «Pegar» or «Pegar y enviar». A failure to
    /// start recording opens the box too, to say why.
    private func recordFromBubble() async {
        if model.isRecording, !state.boxOpen {
            openBox()
        }
        await model.toggleRecording()
        guard !state.boxOpen, let notice = model.notice else { return }
        switch notice {
        case .microphoneDenied, .failed, .notUnderstood, .noTerminal, .cut:
            openBox()
        case .pasted, .sent, .copied, .tooShort:
            break
        }
    }

    private func bubbleDropped(at frame: NSRect) {
        guard let visible = visibleFrame() else { return }
        let next = state.layout.docked
            ? UniConnectDictationBubbleLayout.slid(pillAt: frame, edge: state.layout.edge, in: visible)
            : UniConnectDictationBubbleLayout.settled(
                droppedAt: UniConnectDictationBubbleLayout.bubble(inWindow: frame),
                in: visible
            )
        if next.docked {
            closeBox()
        }
        state.layout = next
        storeLayout()
        place(animated: true)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        if state.layout.docked {
            menu.addItem(MenuAction.item(
                String(localized: "uniconnect.dictation.menu.undock", defaultValue: "Sacar el botón")
            ) { [weak self] in self?.undock() })
        } else {
            menu.addItem(MenuAction.item(
                state.boxOpen
                    ? String(localized: "uniconnect.dictation.menu.closeBox", defaultValue: "Cerrar la caja de dictado")
                    : String(localized: "uniconnect.dictation.menu.openBox.v2", defaultValue: "Abrir la caja y el historial")
            ) { [weak self] in self?.toggleBox() })
            if model.isRecording {
                menu.addItem(MenuAction.item(
                    String(localized: "uniconnect.dictation.discard", defaultValue: "Descartar")
                ) { [weak self] in self?.model.cancelRecording() })
            }
            menu.addItem(MenuAction.item(
                String(localized: "uniconnect.dictation.dock", defaultValue: "Esconder el botón en el borde")
            ) { [weak self] in self?.dock() })
            if defaults.string(forKey: Keys.boxFrame) != nil {
                menu.addItem(MenuAction.item(
                    String(localized: "uniconnect.dictation.menu.placeBox", defaultValue: "Colocar la caja junto al botón")
                ) { [weak self] in self?.placeBoxBesideButton() })
            }
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(
            String(localized: "uniconnect.dictation.menu.hide", defaultValue: "Ocultar el botón (vuelve con UniConnect › Dictado por voz…)")
        ) { [weak self] in self?.hideButton() })
        return menu
    }

    private func makeBubblePanel() -> UniConnectDictationPanel {
        let panel = UniConnectDictationPanel(acceptsKey: false, windowShadow: false)
        let drawing = NSHostingView(rootView: UniConnectDictationBubbleView(model: model, state: state))
        drawing.sizingOptions = []
        let host = UniConnectDictationBubbleHostView(state: state, content: drawing)
        host.onClick = { [weak self] modifiers in self?.bubbleClicked(modifiers) }
        host.onDragEnded = { [weak self] frame in self?.bubbleDropped(at: frame) }
        host.menuProvider = { [weak self] in self?.contextMenu() }
        panel.contentView = host
        bubbleHost = host
        return panel
    }

    private func makeBoxPanel() -> UniConnectDictationPanel {
        let panel = UniConnectDictationPanel(acceptsKey: true, movable: true)
        panel.minSize = Self.boxMinimumSize
        panel.delegate = self
        let root = UniConnectDictationBoxView(
            model: model,
            bubble: state,
            onClose: { [weak self] in self?.closeBox() },
            onDock: { [weak self] in self?.dock() },
            onOpenMicrophoneSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.closeBox() }
        return panel
    }

    private func storeLayout() {
        defaults.set(state.layout.edge.rawValue, forKey: Keys.edge)
        defaults.set(Double(state.layout.bottomOffset), forKey: Keys.bottomOffset)
        defaults.set(state.layout.docked, forKey: Keys.docked)
    }

    private static func storedLayout(in defaults: UserDefaults) -> UniConnectDictationBubbleLayout {
        var layout = UniConnectDictationBubbleLayout()
        if let edge = defaults.string(forKey: Keys.edge).flatMap(UniConnectDictationBubbleLayout.Edge.init(rawValue:)) {
            layout.edge = edge
        }
        if let offset = defaults.object(forKey: Keys.bottomOffset) as? Double {
            layout.bottomOffset = CGFloat(offset)
        }
        layout.docked = defaults.bool(forKey: Keys.docked)
        return layout
    }

    /// A menu item that runs a closure; the item keeps it alive.
    private final class MenuAction: NSObject {
        private let handler: () -> Void

        private init(handler: @escaping () -> Void) {
            self.handler = handler
        }

        static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
            let action = MenuAction(handler: handler)
            let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
            item.target = action
            item.representedObject = action
            return item
        }

        @objc private func run() {
            handler()
        }
    }
}

extension UniConnectDictationPanelController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        rememberBoxFrame(of: notification)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberBoxFrame(of: notification)
    }

    /// The user moved or resized the box: it opens there from now on.
    private func rememberBoxFrame(of notification: Notification) {
        guard !placingBox, let window = notification.object as? NSWindow, window === boxPanel, window.isVisible else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: Keys.boxFrame)
    }
}
