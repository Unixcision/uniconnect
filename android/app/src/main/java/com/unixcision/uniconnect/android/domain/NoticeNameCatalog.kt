package com.unixcision.uniconnect.android.domain

/**
 * Remembers, per machine, the names of its workspaces and windows.
 *
 * Notices arrive with ids only, and often while the app is in the background with no inventory in
 * memory, so the names have to outlive the process: the last inventory seen is kept on disk.
 */
interface NoticeNameCatalog {
    /** Stores the names in [snapshot] for [machineID], replacing what was known before. */
    suspend fun remember(machineID: String, snapshot: MachineSnapshot)

    /** The names behind [notice] on [machineID], or ``NoticeNames.NONE`` when unknown. */
    suspend fun lookup(machineID: String, notice: RemoteNotice): NoticeNames
}
