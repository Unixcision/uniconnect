package com.unixcision.uniconnect.android.domain

/**
 * Favourites and ordering the phone keeps for one machine when its host cannot keep them yet.
 *
 * The host is the source of truth: a host that supports the update RPC gets the change and the
 * snapshot it returns is what the phone shows. Only a host without that RPC falls back to these,
 * so favourites and order still work there, just not shared with the desktop.
 */
data class BoxOverrides(
    val pinnedWorkspaces: Set<String> = emptySet(),
    val pinnedWindows: Set<String> = emptySet(),
    val workspaceOrder: List<String> = emptyList(),
    val windowOrder: Map<String, List<String>> = emptyMap(),
) {
    val isEmpty: Boolean get() = pinnedWorkspaces.isEmpty() && pinnedWindows.isEmpty() && workspaceOrder.isEmpty() && windowOrder.isEmpty()
}
