import SwiftUI

/// The hit-testable region of the full-width custom titlebar band, with the
/// leading and trailing lanes owned by other chrome carved out.
///
/// The band is laid out across the whole window and composited above the app
/// content (`zIndex(100)`), so a plain `Rectangle()` content shape makes every
/// pixel of that strip win SwiftUI's hit test — including the pixels sitting over
/// UniConnect's expanded sidebar header and over the right sidebar's mode bar.
/// Both of those own interactive controls inside the titlebar-height strip, and a
/// full-width shape swallows their clicks before the controls ever see them.
///
/// Insetting only the band's drag surfaces is not sufficient: the content shape is
/// applied to the container, so it captures the click regardless of which child
/// declined it.
///
/// ```swift
/// .contentShape(TitlebarBandInteractiveShape(leadingInset: sidebarLaneWidth))
/// ```
struct TitlebarBandInteractiveShape: Shape {
    /// Width of the leading lane to cede, measured from the band's leading edge.
    var leadingInset: CGFloat = 0
    /// Width of the trailing lane to cede, measured from the band's trailing edge.
    var trailingInset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let width = rect.width - leadingInset - trailingInset
        guard width > 0 else { return Path() }
        return Path(
            CGRect(
                x: rect.minX + leadingInset,
                y: rect.minY,
                width: width,
                height: rect.height
            )
        )
    }
}
