import AppKit
import SwiftUI

/// UniConnect's own traffic lights.
///
/// Rendered in place of AppKit's, which ``WindowDecorationsController`` hides
/// while this is on screen. Matching the system's behaviour means three things
/// beyond the colours: the group desaturates together when the window resigns
/// key, the glyphs appear on hover over *any* of the three rather than each one
/// separately, and an unavailable control (minimize in full screen) stays grey and
/// glyph-less.
struct UniConnectWindowControls: View {
    /// Window the controls act on.
    let window: NSWindow?

    @State private var isHoveringGroup = false
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// Diameter of the painted control, matching AppKit's.
    static let controlDiameter: CGFloat = 12
    /// Mouse target allocated to each control. The painted circles stay 12 points
    /// across while their centres retain AppKit's 20-point cadence.
    static let controlHitTarget: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            ForEach(UniConnectWindowControlKind.allCases) { kind in
                let isEnabled = kind.isEnabled(for: window)
                Button {
                    kind.perform(on: window)
                } label: {
                    Circle()
                        .fill(fill(for: kind, isEnabled: isEnabled))
                        .frame(width: Self.controlDiameter, height: Self.controlDiameter)
                        .overlay {
                            if isHoveringGroup, isEnabled {
                                Image(systemName: kind.hoverSymbol)
                                    .font(.system(size: 6.5, weight: .bold))
                                    .foregroundStyle(Color.black.opacity(0.55))
                            }
                        }
                        .frame(width: Self.controlHitTarget, height: Self.controlHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind.accessibilityLabel)
                .accessibilityIdentifier(kind.accessibilityIdentifier)
                .disabled(!isEnabled)
            }
        }
        // One tracking area for the row: the system reveals all three glyphs when
        // the pointer is over any of them, not just the one under it.
        .onHover { isHoveringGroup = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHoveringGroup)
        .titlebarInteractiveControl()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("uniConnectWindowControls")
    }

    private func fill(for kind: UniConnectWindowControlKind, isEnabled: Bool) -> Color {
        guard controlActiveState != .inactive, isEnabled else {
            let baseOpacity = colorScheme == .dark ? 0.20 : 0.16
            return Color.primary.opacity(
                colorSchemeContrast == .increased ? baseOpacity + 0.10 : baseOpacity
            )
        }
        return kind.activeColor
    }
}
