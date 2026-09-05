import CoreGraphics

/// Geometry for UniConnect's sidebar header row.
///
/// Every value here is a free choice, not a measurement of AppKit. The window
/// controls in this row are drawn by ``UniConnectWindowControls`` rather than by
/// the system, so nothing repositions behind the layout and the same numbers hold
/// in a window and in full screen.
enum UniConnectSidebarHeaderMetrics {
    /// Vertical centre of the control row, in window coordinates.
    ///
    /// This is AppKit's own traffic-light centre line. UniConnect draws its
    /// buttons rather than using AppKit's, but keeping them on the system's line
    /// means the row sits where a Mac user expects it — and, more importantly,
    /// that expanded and compact put it in exactly the same place, so the controls
    /// do not jump when the sidebar changes shape.
    static let controlCenterY: CGFloat = 16

    /// Height of the header row.
    ///
    /// Twice ``controlCenterY``, so centring the row's contents inside it lands
    /// them on that line with no offset to tune.
    static var rowHeight: CGFloat { controlCenterY * 2 }
    /// Inset from the sidebar's leading edge to the first window control.
    static let leadingInset: CGFloat = 14
    /// Inset from the sidebar's trailing edge to the action cluster.
    static let trailingInset: CGFloat = 12

    /// Height of the grouped action cluster.
    static let clusterHeight: CGFloat = 24
    /// Corner radius of the cluster; a capsule at this height.
    static let clusterCornerRadius: CGFloat = 12
    /// Inset between the cluster's edge and its buttons.
    static let clusterPadding: CGFloat = 2
    /// Edge length of one action button.
    static var buttonHeight: CGFloat { clusterHeight - (clusterPadding * 2) }
    /// Width of one action button, wider than tall so the pair reads as two halves
    /// of a capsule rather than two circles inside one.
    static var buttonWidth: CGFloat { buttonHeight + 6 }
    /// Corner radius of a button, concentric with the cluster.
    static var buttonCornerRadius: CGFloat { clusterCornerRadius - clusterPadding }
    /// Point size of an action button's SF Symbol.
    static let buttonIconSize: CGFloat = 13
    /// Height of the hairline between adjacent buttons, as a fraction of the
    /// button height, so it stays clear of the capsule's rounded ends.
    static let separatorHeightRatio: CGFloat = 0.55

    /// Diameter of the unread-count badge.
    static let badgeDiameter: CGFloat = 14
    /// Width of the ring separating the badge from the glyph beneath it.
    static let badgeRingWidth: CGFloat = 1.5
}
