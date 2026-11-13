import SwiftUI

/// The voice meter under the timer: a bar that fills with the level, from 0 to 1.
struct UniConnectDictationLevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(Color.red.gradient)
                    .frame(width: max(4, proxy.size.width * min(1, max(0, level))))
            }
        }
    }
}
