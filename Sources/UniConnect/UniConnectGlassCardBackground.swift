import SwiftUI

/// A single glass/material surface used by the window-scoped rail flyout.
struct UniConnectGlassCardBackground: View {
    let cornerRadius: CGFloat
    let reduceTransparency: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

#if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            shape
                .fill(Color.clear)
                .glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8))
        } else {
            fallback(shape)
        }
#else
        fallback(shape)
#endif
    }

    @ViewBuilder
    private func fallback(_ shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            shape
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.8))
        } else {
            shape
                .fill(.regularMaterial)
                .overlay(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.18)))
                .overlay(shape.strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8))
                .overlay(shape.strokeBorder(Color.black.opacity(0.16), lineWidth: 0.8).padding(-0.8))
        }
    }
}
