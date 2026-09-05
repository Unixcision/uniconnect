import AppKit
import SwiftUI

/// Semantic colours reserved by the compact rail.
enum UniConnectRailPalette {
    static let railGradientStartOpacity = 1.0
    static let railGradientEndOpacity = 0.78
    static let flyoutGradientStartOpacity = 0.98
    static let flyoutGradientEndOpacity = 0.74

    static func badgeFillOpacity(increasedContrast: Bool) -> Double {
        increasedContrast ? 0.16 : 0.10
    }

    static func compactBadgeBackgroundOpacity(increasedContrast: Bool) -> Double {
        increasedContrast ? 0.92 : 0.72
    }

    // Compact status glyphs sit over a dark badge regardless of the app appearance.
    static let compactDisconnectedForegroundNSColor = NSColor(
        srgbRed: 1,
        green: 185.0 / 255.0,
        blue: 102.0 / 255.0,
        alpha: 1
    )

    /// A stable semantic tint that stays readable over the flyout in either appearance.
    static func connectionBadgeNSColor(
        for kind: UniConnectChipSnapshot.ConnectionKind,
        colorScheme: ColorScheme
    ) -> NSColor {
        switch (kind, colorScheme) {
        case (.local, .dark):
            return NSColor(srgbRed: 100.0 / 255.0, green: 216.0 / 255.0, blue: 137.0 / 255.0, alpha: 1)
        case (.local, _):
            return NSColor(srgbRed: 23.0 / 255.0, green: 107.0 / 255.0, blue: 58.0 / 255.0, alpha: 1)
        case (.ssh, .dark):
            return NSColor(srgbRed: 102.0 / 255.0, green: 183.0 / 255.0, blue: 1, alpha: 1)
        case (.ssh, _):
            return NSColor(srgbRed: 11.0 / 255.0, green: 92.0 / 255.0, blue: 153.0 / 255.0, alpha: 1)
        case (.mixed, .dark):
            return NSColor(srgbRed: 193.0 / 255.0, green: 147.0 / 255.0, blue: 1, alpha: 1)
        case (.mixed, _):
            return NSColor(srgbRed: 107.0 / 255.0, green: 58.0 / 255.0, blue: 165.0 / 255.0, alpha: 1)
        }
    }

    static func disconnectedBadgeNSColor(for colorScheme: ColorScheme) -> NSColor {
        if colorScheme == .dark {
            return NSColor(srgbRed: 1, green: 185.0 / 255.0, blue: 102.0 / 255.0, alpha: 1)
        }
        return NSColor(srgbRed: 133.0 / 255.0, green: 68.0 / 255.0, blue: 0, alpha: 1)
    }

    // White small text remains above a 4.5:1 contrast ratio on this semantic badge.
    static let unreadNSColor = NSColor(
        srgbRed: 214.0 / 255.0,
        green: 46.0 / 255.0,
        blue: 87.0 / 255.0,
        alpha: 1
    )
    static let unread = Color(nsColor: unreadNSColor)

    static var railGradientMidpointOpacity: CGFloat {
        CGFloat((railGradientStartOpacity + railGradientEndOpacity) / 2)
    }

    static var flyoutGradientMidpointOpacity: CGFloat {
        CGFloat((flyoutGradientStartOpacity + flyoutGradientEndOpacity) / 2)
    }

    static func appKitAppearance(for colorScheme: ColorScheme) -> NSAppearance? {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }

    static func windowBackgroundNSColor(for colorScheme: ColorScheme) -> NSColor {
        guard let appearance = appKitAppearance(for: colorScheme) else {
            return .windowBackgroundColor
        }
        let dynamicBackground = NSColor.windowBackgroundColor
        var resolvedBackground = dynamicBackground
        appearance.performAsCurrentDrawingAppearance {
            resolvedBackground = dynamicBackground.usingColorSpace(.sRGB) ?? dynamicBackground
        }
        return resolvedBackground
    }

    static func identityBackgroundNSColor(
        baseColor: NSColor,
        layerOpacity: CGFloat,
        gradientOpacity: CGFloat,
        surfaceColor: NSColor
    ) -> NSColor {
        let clampedLayerOpacity = max(0, min(layerOpacity, 1))
        let clampedGradientOpacity = max(0, min(gradientOpacity, 1))
        return cmuxCompositedNSColor(
            baseColor.withAlphaComponent(clampedLayerOpacity * clampedGradientOpacity),
            over: surfaceColor
        )
    }

    static func identityForegroundNSColor(
        baseColor: NSColor,
        layerOpacity: CGFloat,
        gradientOpacity: CGFloat,
        surfaceColor: NSColor
    ) -> NSColor {
        let background = identityBackgroundNSColor(
            baseColor: baseColor,
            layerOpacity: layerOpacity,
            gradientOpacity: gradientOpacity,
            surfaceColor: surfaceColor
        )
        return cmuxReadableForegroundNSColor(on: background, opacity: 1)
    }
}
