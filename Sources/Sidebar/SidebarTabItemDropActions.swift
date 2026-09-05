import SwiftUI

/// Closure-only behavior for a drop target below the sidebar's lazy-list boundary.
@MainActor
struct SidebarTabItemDropActions {
    let validate: (DropInfo, CGFloat) -> Bool
    let entered: (DropInfo, CGFloat) -> Void
    let exited: (DropInfo, CGFloat) -> Void
    let updated: (DropInfo, CGFloat) -> DropProposal?
    let perform: (DropInfo, CGFloat) -> Bool

    static func forwarding<Delegate: DropDelegate>(
        to makeDelegate: @escaping (CGFloat) -> Delegate
    ) -> Self {
        Self(
            validate: { info, rowHeight in
                makeDelegate(rowHeight).validateDrop(info: info)
            },
            entered: { info, rowHeight in
                makeDelegate(rowHeight).dropEntered(info: info)
            },
            exited: { info, rowHeight in
                makeDelegate(rowHeight).dropExited(info: info)
            },
            updated: { info, rowHeight in
                makeDelegate(rowHeight).dropUpdated(info: info)
            },
            perform: { info, rowHeight in
                makeDelegate(rowHeight).performDrop(info: info)
            }
        )
    }
}
