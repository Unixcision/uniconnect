import AppKit

/// Native sender with an owning window, so the fail-closed action gate can identify a lock control.
final class UniConnectLockButton: NSButton {
    var onPress: () -> Void = {}

    init(title: String, prominent: Bool, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        self.onPress = action
        bezelStyle = .rounded
        controlSize = .large
        font = .systemFont(ofSize: 17, weight: .semibold)
        appearance = NSAppearance(named: .darkAqua)
        if prominent {
            bezelColor = .systemPink
            image = NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)
            imagePosition = .imageLeading
        }
        target = self
        self.action = #selector(press)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // AppKit's target/action boundary requires an Objective-C selector.
    @objc private func press() { onPress() }
}
