import SwiftUI

/// Value adapter that forwards drop events through closure actions only.
@MainActor
struct SidebarTabItemDropDelegate: DropDelegate {
    let actions: SidebarTabItemDropActions
    let rowHeight: CGFloat

    func validateDrop(info: DropInfo) -> Bool {
        actions.validate(info, rowHeight)
    }

    func dropEntered(info: DropInfo) {
        actions.entered(info, rowHeight)
    }

    func dropExited(info: DropInfo) {
        actions.exited(info, rowHeight)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        actions.updated(info, rowHeight)
    }

    func performDrop(info: DropInfo) -> Bool {
        actions.perform(info, rowHeight)
    }
}
