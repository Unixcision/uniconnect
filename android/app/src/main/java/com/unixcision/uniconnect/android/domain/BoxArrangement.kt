package com.unixcision.uniconnect.android.domain

/**
 * How boxes are shown: favourites first, then the host's own order, with the phone's local order
 * on top of both when the host does not keep one.
 *
 * Pure so the rules can be tested without a host: the same function serves workspaces and the
 * windows inside one.
 */
object BoxArrangement {
    /**
     * Orders [items] by [id]: anything in [localOrder] first, in that order, then the rest as they
     * came; within that, favourites ([pinned] or the host's own flag) come before the others.
     */
    fun <T> arrange(items: List<T>, id: (T) -> String, hostPinned: (T) -> Boolean, pinned: Set<String>, localOrder: List<String>): List<T> {
        val rank = localOrder.withIndex().associate { (index, value) -> value to index }
        val ordered = items.withIndex().sortedWith(compareBy({ rank[id(it.value)] ?: (rank.size + it.index) }))
            .map { it.value }
        return ordered.filter { hostPinned(it) || id(it) in pinned } + ordered.filter { !(hostPinned(it) || id(it) in pinned) }
    }

    /** The workspaces of [snapshot] as the phone shows them. */
    fun workspaces(snapshot: MachineSnapshot, overrides: BoxOverrides): List<RemoteWorkspace> =
        arrange(snapshot.workspaces, { it.id }, { it.isPinned }, overrides.pinnedWorkspaces, overrides.workspaceOrder)

    /** The windows of [workspace] as the phone shows them. */
    fun windows(workspace: RemoteWorkspace, overrides: BoxOverrides): List<RemoteWindow> =
        arrange(workspace.windows, { it.id }, { it.isPinned }, overrides.pinnedWindows, overrides.windowOrder[workspace.id] ?: emptyList())

    /** The order list after moving [id] by [delta] positions (negative = up); ids not listed keep their place. */
    fun moved(current: List<String>, id: String, delta: Int): List<String> {
        val order = current.toMutableList()
        val from = order.indexOf(id)
        if (from < 0) return current
        order.removeAt(from)
        order.add((from + delta).coerceIn(0, order.size), id)
        return order
    }

    /** [ids] with [id] first. */
    fun movedToTop(current: List<String>, id: String): List<String> =
        listOf(id) + current.filter { it != id }
}
