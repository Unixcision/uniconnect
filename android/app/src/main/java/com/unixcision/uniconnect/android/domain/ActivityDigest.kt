package com.unixcision.uniconnect.android.domain

/**
 * What the AIs of every machine are doing, sorted for the home.
 *
 * - [waiting]: windows whose AI waits for the reader, the most recent first.
 * - [working]: windows whose AI is working, the most recent first.
 * - [recent]: the latest changes of state over the last day, AI windows only, at most
 *   [RECENT_LIMIT]: "APP 2 te espera", "CODEX está trabajando", "UNICONNECT CODEX pasó a reposo".
 *
 * Built from the hosts' own `since` (contract `activity.v1`), so it needs no history of its own
 * and says the same after the app restarts. Only machines that answer count: the last list of
 * one that does not is a picture of the past.
 */
data class ActivityDigest(
    val waiting: List<ActivityItem>,
    val working: List<ActivityItem>,
    val recent: List<ActivityItem>,
) {
    companion object {
        const val RECENT_LIMIT = 6
        private const val RECENT_SECONDS = 24 * 60 * 60L

        val empty = ActivityDigest(emptyList(), emptyList(), emptyList())

        /** The digest of [machines], each with its last workspace list from [snapshots], counting only [connected] ones. */
        fun of(machines: List<Machine>, snapshots: Map<String, MachineSnapshot?>, connected: Set<String>, nowEpochSeconds: Long): ActivityDigest {
            val items = machines.filter { it.id in connected }.flatMap { machine ->
                snapshots[machine.id]?.workspaces.orEmpty().flatMap { workspace ->
                    workspace.windows.mapNotNull { window ->
                        val activity = window.activity?.takeIf { it.state != ActivityState.UNKNOWN } ?: return@mapNotNull null
                        ActivityItem(
                            route = NoticeRoute(machine.id, workspace.id, window.id),
                            machineName = machine.name, workspaceName = workspace.name, windowName = window.name,
                            agent = activity.agent?.trim()?.takeIf { it.isNotEmpty() }, state = activity.state,
                            sinceEpochSeconds = activity.sinceEpochSeconds?.takeIf { it > 0 },
                        )
                    }
                }
            }
            val newestFirst = compareByDescending<ActivityItem> { it.sinceEpochSeconds ?: Long.MIN_VALUE }
            return ActivityDigest(
                waiting = items.filter { it.state == ActivityState.WAITING }.sortedWith(newestFirst),
                working = items.filter { it.state == ActivityState.WORKING }.sortedWith(newestFirst),
                // A shell that went quiet is not news; an AI that stopped is.
                recent = items.filter { item ->
                    val since = item.sinceEpochSeconds ?: return@filter false
                    (item.agent != null || item.state != ActivityState.IDLE) && nowEpochSeconds - since in 0..RECENT_SECONDS
                }.sortedWith(newestFirst).take(RECENT_LIMIT),
            )
        }
    }
}
