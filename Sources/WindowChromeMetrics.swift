import CoreGraphics

enum WindowChromeMetrics {
    static let sharedChromeBarHeight: CGFloat = 32
    static let appTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let bonsplitTabBarHeight: CGFloat = sharedChromeBarHeight
    static let secondaryTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let minimumTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let maximumTitlebarHeight: CGFloat = 72
    static let defaultTitlebarHeight: CGFloat = sharedChromeBarHeight

    static func clampedTitlebarHeight(_ height: CGFloat) -> CGFloat {
        max(minimumTitlebarHeight, min(maximumTitlebarHeight, height))
    }
}

enum MinimalModeChromeMetrics {
    static let titlebarHeight: CGFloat = WindowChromeMetrics.appTitlebarHeight
}

/// Geometry shared by the two UniConnect sidebar presentations.
enum UniConnectSidebarChromeMetrics {
    /// The compact floating panel's breathing room from the window edges.
    static let panelInset: CGFloat = 10
    /// The expanded sidebar emulates the symmetric card inset of a native
    /// macOS 26 split-view sidebar while the root backdrop still fills the window.
    static let expandedPanelInset: CGFloat = 8
    static let expandedLeadingInset: CGFloat = expandedPanelInset
    /// The expanded card keeps the same breathing room on every window edge.
    /// Its complete header moves with the card, keeping traffic lights and actions
    /// on one internally aligned row.
    static let expandedTopInset: CGFloat = expandedPanelInset
    static let expandedBottomInset: CGFloat = expandedPanelInset
    static let expandedTrailingInset: CGFloat = expandedPanelInset
    /// The compact rail deliberately begins below the native titlebar controls.
    static let compactTopInset: CGFloat = WindowChromeMetrics.appTitlebarHeight + panelInset
    /// Root-level compact controls use the expanded card's top breathing room,
    /// so both presentations share one global centre line.
    static let compactWindowControlsTopInset: CGFloat = expandedTopInset
    static let compactBottomInset: CGFloat = panelInset
    static var expandedHeaderHeight: CGFloat { UniConnectSidebarHeaderMetrics.rowHeight }
    static var globalWindowControlCenterY: CGFloat {
        expandedTopInset + UniConnectSidebarHeaderMetrics.controlCenterY
    }

    static func panelTopInset(isCompact: Bool) -> CGFloat {
        isCompact ? compactTopInset : expandedTopInset
    }

    static func panelLeadingInset(isCompact: Bool) -> CGFloat {
        isCompact ? panelInset : expandedLeadingInset
    }

    static func panelTrailingInset(isCompact: Bool) -> CGFloat {
        isCompact ? panelInset : expandedTrailingInset
    }

    static func panelBottomInset(isCompact: Bool) -> CGFloat {
        isCompact ? compactBottomInset : expandedBottomInset
    }

    /// Compact mode reveals the shared full-window backdrop instead of
    /// compositing a second material surface with a slightly different tone.
    static func usesDistinctPanelSurface(isCompact: Bool) -> Bool {
        !isCompact
    }
}

enum HeaderChromeControlMetrics {
    static let buttonSize: CGFloat = 20
    static let iconSize: CGFloat = 12
    static let iconFrameSize: CGFloat = 14
    static let cornerRadius: CGFloat = 8
    static let titlebarControlsLeadingPadding: CGFloat = 4

    static func iconFrameSize(forIconSize iconSize: CGFloat) -> CGFloat {
        max(Self.iconFrameSize, iconSize + 2)
    }
}

enum RightSidebarChromeMetrics {
    static let titlebarHeight: CGFloat = WindowChromeMetrics.appTitlebarHeight
    static let secondaryBarHeight: CGFloat = WindowChromeMetrics.secondaryTitlebarHeight
    static let barHorizontalPadding: CGFloat = 8
    static let barVerticalPadding: CGFloat = 4
    static let controlHeight: CGFloat = secondaryBarHeight - (barVerticalPadding * 2)
    static let controlHorizontalPadding: CGFloat = 8
    static let controlCornerRadius: CGFloat = 5
    static let headerControlSize: CGFloat = HeaderChromeControlMetrics.buttonSize
    static let headerIconSize: CGFloat = 10
    static let headerIconFrameSize: CGFloat = headerIconSize
    static let headerControlSpacing: CGFloat = 4
    static let headerControlCornerRadius: CGFloat = HeaderChromeControlMetrics.cornerRadius
    static let headerControlCenterAlignmentAdjustment: CGFloat = 0
}

enum SidebarWorkspaceListMetrics {
    static let firstRowTopOffset: CGFloat = MinimalModeChromeMetrics.titlebarHeight + 2
    static let rowVerticalPadding: CGFloat = 8
    static let topScrimHeight: CGFloat = firstRowTopOffset + 20
    static let bottomScrimHeight: CGFloat = topScrimHeight

    static var scrollTopInset: CGFloat {
        max(0, firstRowTopOffset - rowVerticalPadding)
    }
}

struct SidebarWorkspaceScrollInsets: Equatable {
    static let workspaceList = SidebarWorkspaceScrollInsets(
        top: SidebarWorkspaceListMetrics.scrollTopInset,
        bottom: SidebarWorkspaceListMetrics.bottomScrimHeight
    )

    static let uniConnectWorkspaceList = SidebarWorkspaceScrollInsets(
        top: UniConnectSidebarHeaderMetrics.rowHeight + 6,
        bottom: SidebarWorkspaceListMetrics.bottomScrimHeight
    )

    let top: CGFloat
    let bottom: CGFloat

    nonisolated var total: CGFloat {
        top + bottom
    }
}

enum SidebarWorkspaceScrollLayout {
    nonisolated static func contentMinHeight(
        viewportHeight: CGFloat,
        insets: SidebarWorkspaceScrollInsets
    ) -> CGFloat {
        max(0, viewportHeight - insets.total)
    }
}
