import SwiftUI

/// SwiftUI colors of `contracts/accounts-v1/paleta.json`.
struct UniConnectAccountsPalette {
    /// The account color for a palette index, or the neutral gray for `nil`.
    static func color(_ index: Int?) -> Color {
        let hex = index.map { UniConnectAccountsUsageMath.paletteHex[$0 % 8] } ?? UniConnectAccountsUsageMath.neutralHex
        return Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// The color of an email (or neutral without one).
    static func color(email: String?) -> Color {
        color(email.map { UniConnectAccountsUsageMath.colorIndex(email: $0) })
    }

    /// Ring color for a usage percentage: green, amber from 70 %, red from 90 %.
    static func usage(_ percent: Double) -> Color {
        switch percent {
        case 90...: color(0)
        case 70...: color(1)
        default: color(2)
        }
    }
}
