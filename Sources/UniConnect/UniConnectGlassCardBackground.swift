import SwiftUI

/// Applies one adaptive glass/material surface to the window-scoped rail flyout.
struct UniConnectGlassCardBackground: ViewModifier {
    let cornerRadius: CGFloat
    let reduceTransparency: Bool
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

#if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(.regular, in: shape)
                .overlay(
                    shape.strokeBorder(
                        Color.primary.opacity(increasedContrast ? 0.42 : 0.20),
                        lineWidth: increasedContrast ? 1.2 : 0.8
                    )
                )
        } else {
            content.background(fallback(shape))
        }
#else
        content.background(fallback(shape))
#endif
    }

    @ViewBuilder
    private func fallback(_ shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            shape
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    shape.strokeBorder(
                        Color.primary.opacity(increasedContrast ? 0.46 : 0.18),
                        lineWidth: increasedContrast ? 1.2 : 0.8
                    )
                )
        } else {
            shape
                .fill(.regularMaterial)
                .overlay(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.18)))
                .overlay(
                    shape.strokeBorder(
                        Color.primary.opacity(increasedContrast ? 0.42 : 0.20),
                        lineWidth: increasedContrast ? 1.2 : 0.8
                    )
                )
        }
    }
}
