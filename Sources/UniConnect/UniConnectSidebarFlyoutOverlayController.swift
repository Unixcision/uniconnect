import AppKit
import ObjectiveC
import QuartzCore
import SwiftUI

private var uniConnectSidebarFlyoutControllerKey: UInt8 = 0

/// Owns the single non-window-creating rail flyout installed in each main window.
@MainActor
final class UniConnectSidebarFlyoutOverlayController: NSObject {
    struct SourceContext {
        let snapshot: UniConnectChipSnapshot
        let actions: UniConnectChipActions
        let anchorFrameInWindow: CGRect
        let reduceMotion: Bool
        let reduceTransparency: Bool
    }

    private weak var window: NSWindow?
    private let containerView = UniConnectSidebarFlyoutContainerView(frame: .zero)
    private let corridorView = UniConnectSidebarFlyoutCorridorView(frame: .zero)
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var installationConstraints: [NSLayoutConstraint] = []
    private weak var installedContainerView: NSView?
    private weak var installedReferenceView: NSView?
    private var sourceContexts: [UUID: SourceContext] = [:]
    private var policy = UniConnectSidebarFlyoutPolicy()
    private var scheduledShow: DispatchWorkItem?
    private var scheduledHide: DispatchWorkItem?
    private var escapeMonitor: Any?
    private var windowDidResignKeyObserver: NSObjectProtocol?
    private var windowDidResizeObserver: NSObjectProtocol?

    /// Exposed to tests without revealing the concrete overlay subview hierarchy.
    var debugAcceptsFirstResponder: Bool { containerView.acceptsFirstResponder }

    init(window: NSWindow) {
        self.window = window
        super.init()

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.isHidden = true
        containerView.alphaValue = 0
        containerView.identifier = NSUserInterfaceItemIdentifier("uniconnect.sidebar.flyout.overlay")

        corridorView.onHoverChanged = { [weak self] isInside in
            self?.handle(.corridorChanged(isInside: isInside))
        }
        corridorView.isHidden = true
        containerView.addSubview(corridorView)

        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.isHidden = true
        containerView.addSubview(hostingView, positioned: .above, relativeTo: corridorView)

        windowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handle(.escape)
            }
        }
        windowDidResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.relayoutVisibleSource()
            }
        }

        _ = ensureInstalled()
    }

    deinit {
        scheduledShow?.cancel()
        scheduledHide?.cancel()
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        if let windowDidResignKeyObserver {
            NotificationCenter.default.removeObserver(windowDidResignKeyObserver)
        }
        if let windowDidResizeObserver {
            NotificationCenter.default.removeObserver(windowDidResizeObserver)
        }
    }

    func updateSource(id: UUID, context: SourceContext) {
        sourceContexts[id] = context
        guard policy.visibleSourceID == id else { return }
        showNow(id: id, animateMove: true)
    }

    func pointerChanged(id: UUID, isInside: Bool) {
        handle(isInside ? .pointerEntered(id) : .pointerExited(id))
    }

    func focusChanged(id: UUID, isFocused: Bool) {
        handle(.focusChanged(id, isFocused: isFocused))
    }

    func removeSource(id: UUID) {
        sourceContexts.removeValue(forKey: id)
        handle(.sourceRemoved(id))
    }

    func dismiss() {
        handle(.escape)
    }

    private func handle(_ event: UniConnectSidebarFlyoutPolicy.Event) {
        let effect = policy.reduce(event)
        apply(effect)
    }

    private func apply(_ effect: UniConnectSidebarFlyoutPolicy.Effect) {
        switch effect {
        case .none:
            break

        case .scheduleShow(let id, let milliseconds):
            scheduledShow?.cancel()
            scheduledHide?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.scheduledShow = nil
                self?.handle(.showDelayElapsed(id))
            }
            scheduledShow = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(milliseconds),
                execute: workItem
            )

        case .showNow(let id):
            scheduledShow?.cancel()
            scheduledShow = nil
            scheduledHide?.cancel()
            scheduledHide = nil
            showNow(id: id, animateMove: !containerView.isHidden)

        case .scheduleHide(let milliseconds):
            scheduledShow?.cancel()
            scheduledShow = nil
            scheduledHide?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.scheduledHide = nil
                self?.handle(.closeDelayElapsed)
            }
            scheduledHide = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(milliseconds),
                execute: workItem
            )

        case .hideNow:
            scheduledShow?.cancel()
            scheduledShow = nil
            scheduledHide?.cancel()
            scheduledHide = nil
            hideNow()

        case .cancelScheduledHide:
            scheduledHide?.cancel()
            scheduledHide = nil
        }
    }

    private func showNow(id: UUID, animateMove: Bool) {
        guard let context = sourceContexts[id], ensureInstalled() else {
            hideNow()
            return
        }

        containerView.superview?.addSubview(containerView, positioned: .above, relativeTo: nil)
        containerView.superview?.layoutSubtreeIfNeeded()

        let anchorFrame = containerView.convert(context.anchorFrameInWindow, from: nil)
        let layout = UniConnectSidebarFlyoutLayout.resolve(
            containerBounds: containerView.bounds,
            anchorFrame: anchorFrame,
            windowCount: context.snapshot.windows.count
        )

        let root = UniConnectSidebarFlyoutView(
            snapshot: context.snapshot,
            reduceMotion: context.reduceMotion,
            reduceTransparency: context.reduceTransparency,
            onSelectWindow: { [weak self] workspaceID, panelID in
                context.actions.selectWindow(workspaceID, panelID)
                self?.dismiss()
            },
            onPerformLocalWindowAction: { workspaceID, panelID, action in
                context.actions.performLocalWindowAction(workspaceID, panelID, action)
            },
            onReconnectSSHWindow: { workspaceID, panelID in
                context.actions.reconnectSSHWindowNow(workspaceID, panelID)
            },
            onHoverChanged: { [weak self] isInside in
                self?.handle(.corridorChanged(isInside: isInside))
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )
        .frame(width: layout.cardFrame.width, height: layout.cardFrame.height, alignment: .topLeading)

        hostingView.rootView = AnyView(root)
        hostingView.isHidden = false
        corridorView.isHidden = false
        corridorView.frame = layout.corridorFrame
        containerView.interactiveLayout = layout

        let shouldAnimate = animateMove && !context.reduceMotion
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = 0.18
                animationContext.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                hostingView.animator().frame = layout.cardFrame
            }
        } else {
            hostingView.frame = layout.cardFrame
        }

        let wasHidden = containerView.isHidden
        containerView.isHidden = false
        if wasHidden && !context.reduceMotion {
            containerView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = 0.12
                containerView.animator().alphaValue = 1
            }
        } else {
            containerView.alphaValue = 1
        }
        installEscapeMonitorIfNeeded()
    }

    private func hideNow() {
        removeEscapeMonitor()
        containerView.alphaValue = 0
        containerView.isHidden = true
        containerView.interactiveLayout = nil
        corridorView.isHidden = true
        hostingView.isHidden = true
        hostingView.rootView = AnyView(EmptyView())
    }

    private func relayoutVisibleSource() {
        guard let id = policy.visibleSourceID else { return }
        showNow(id: id, animateMove: false)
    }

    private func installEscapeMonitorIfNeeded() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  event.keyCode == 53 else {
                return event
            }
            self.dismiss()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window,
              let target = installationTarget(for: window) else {
            return false
        }

        if containerView.superview !== target.container || installedReferenceView !== target.reference {
            NSLayoutConstraint.deactivate(installationConstraints)
            installationConstraints.removeAll()
            containerView.removeFromSuperview()
            target.container.addSubview(containerView, positioned: .above, relativeTo: nil)
            installationConstraints = [
                containerView.topAnchor.constraint(equalTo: target.reference.topAnchor),
                containerView.bottomAnchor.constraint(equalTo: target.reference.bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: target.reference.leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: target.reference.trailingAnchor),
            ]
            NSLayoutConstraint.activate(installationConstraints)
            installedContainerView = target.container
            installedReferenceView = target.reference
        }
        return true
    }

    private func installationTarget(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        if let glassTarget = WindowGlassEffect.portalInstallationTarget(for: window) {
            return glassTarget
        }
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else {
            return nil
        }
        return (themeFrame, contentView)
    }
}

@MainActor
func uniConnectSidebarFlyoutController(for window: NSWindow) -> UniConnectSidebarFlyoutOverlayController {
    if let existing = objc_getAssociatedObject(
        window,
        &uniConnectSidebarFlyoutControllerKey
    ) as? UniConnectSidebarFlyoutOverlayController {
        return existing
    }
    let controller = UniConnectSidebarFlyoutOverlayController(window: window)
    objc_setAssociatedObject(
        window,
        &uniConnectSidebarFlyoutControllerKey,
        controller,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return controller
}
