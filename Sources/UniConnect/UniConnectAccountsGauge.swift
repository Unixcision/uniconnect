import SwiftUI

/// A usage ring: the percentage in the middle, colored green, amber or red by how full it is.
struct UniConnectAccountsGauge: View {
    let percent: Double
    let size: CGFloat
    let lineWidth: CGFloat
    var showsLabel = true

    var body: some View {
        let clamped = min(max(percent, 0), 100)
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped / 100)
                .stroke(
                    UniConnectAccountsPalette.usage(percent),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: clamped)
            if showsLabel {
                Text(verbatim: "\(Int(percent.rounded())) %")
                    .font(.system(size: size * 0.22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
    }
}
