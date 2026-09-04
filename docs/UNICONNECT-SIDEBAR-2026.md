# UniConnect compact rail and flyout

This document is the implementation contract for UniConnect's compact box
sidebar. It complements `docs/UNICONNECT.md`; the expanded cmux sidebar remains
available and the compact state is owned independently by each main window.

## Apple 2026 research basis

The design follows Apple's current macOS guidance instead of imitating a concept
render. Standard context-menu commands remain native SwiftUI/AppKit menu items, so
they inherit the platform's current layout, icon placement, keyboard handling, and
accessibility behavior. The custom card is the one expressive surface: Apple advises
grouping custom glass effects for consistent rendering, keeping transient views
focused on a few related tasks, showing only one at a time, and making custom motion
optional.

Primary references:

- [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)
- [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- [Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)
- [Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers)
- [Testing system accessibility features](https://developer.apple.com/documentation/accessibility/testing-system-accessibility-features-in-your-app)

## Visual language

- The rail is 64 points wide and uses 36-point continuous-corner squircles.
- Every box has a stable two-character monogram and deterministic fallback
  colour. A configured group SF Symbol takes precedence over the monogram.
- Selection is communicated through shape, opacity, border, and scale. The
  identity glyph and status badges keep their contrast while only the coloured
  tile desaturates. A WCAG-small-text-safe coral is reserved for unread activity;
  disconnected boxes desaturate and connection state stays in the lower badge.
- Collapsed groups use a quiet stacked-card silhouette. The rail has one footer
  action for creating a box and one for expanding the sidebar.

## Window-scoped flyout

Each main `NSWindow` owns exactly one
`UniConnectSidebarFlyoutOverlayController`. The controller installs a single
`NSHostingView` into the same window, above the terminal and browser portal
installation target. It must never use `NSPopover`, create a utility window,
activate the app, make the window key, or mutate the first responder.

The card is horizontal and contains:

- the full box or group name and optional SSH host label;
- a window-count badge and a `LOCAL`, `SSH`, or `MIXED` badge;
- unread and Claude notification-bridge state when present;
- the exact terminal-window list. Selecting an entry routes its immutable
  `(workspaceID, panelID)` to
  `tabManager.focusTab(workspaceID, surfaceId: panelID)`.

The card is clamped to the content bounds with a 12-point margin and flips to
the leading side when the trailing side has insufficient space. Its height is
derived from the complete rounded-font name rather than a fixed two-line cap;
when the window is constrained, the window list scrolls before the name is
truncated. The overlay's
root `NSView.hitTest` returns `nil` outside the resolved card and pointer
corridor, preserving interaction with portals underneath.

## Interaction contract

- Initial pointer dwell: 260 ms.
- Close grace period: 140 ms.
- Moving from one rail tile to another while the card is visible switches its
  content immediately.
- Keyboard focus opens the same card immediately. When a transient hover ends,
  the card returns to the focused tile.
- Moving between tile and card through the pointer corridor cancels deferred
  closing.
- Escape and window resignation close the card without forwarding a focus
  change.
- VoiceOver exposes every tile as a named button, includes connection/window/
  unread state, and exposes rename and close custom actions. Window entries are
  individually named buttons.

Reduce Motion disables scale/movement/fade animation. Reduce Transparency uses
an opaque window-background surface. Increased Contrast strengthens borders
and preserves readable glyphs in both appearances. On macOS 26 the card applies
system glass to the complete content surface; macOS 14 and 15 use a single
regular-material card fallback. Badges do not each create their own glass layer.

## Snapshot boundary

`UniConnectRailSidebar` is the only compact-rail view that may observe
`TabManager`, `Workspace`, or `TerminalNotificationStore`. It projects their
state into immutable, `Equatable` `UniConnectChipSnapshot` and
`UniConnectWindowSnapshot` values before the `LazyVStack`. Descendants receive
only those values and `UniConnectChipActions` closures. No store or observable
model may be added to `UniConnectRailRow`, `UniConnectRailTile`, the flyout, or
the window-list subtree.

Snapshot rebuilding is driven by upstream publishers and never schedules or
performs model mutation from a SwiftUI `body` computation. Tile equality ignores
the action bundle and compares only immutable render state.

## Context menu

The compact tile menu reuses application actions and keyboard settings. Its
order is identity, organization, creation/recovery, read state, then destructive
closure:

1. Rename box; edit SSH connection when applicable; expand/collapse a group.
2. Pin or unpin.
3. New window; reconnect eligible SSH windows; update Claude in the box.
4. Mark read or unread.
5. Close box, last and destructive.

All labels and accessibility text use `Resources/Localizable.xcstrings`.

## Regression coverage

`cmuxTests/UniConnectRailTests.swift` covers monogram and colour stability,
small-text contrast, full-name expansion,
snapshot equality, hover/focus/corridor reducer transitions, exact delay values,
card clamping/flipping/hit-testing, exact workspace-and-panel action routing,
and preservation of the first responder during overlay installation.
