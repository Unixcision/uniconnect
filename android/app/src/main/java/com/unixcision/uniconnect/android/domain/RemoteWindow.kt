package com.unixcision.uniconnect.android.domain

data class RemoteWindow(
    val id: String,
    val name: String,
    val kind: String,
    val isPinned: Boolean = false,
    val activity: RemoteActivity? = null,
    /**
     * When the reader last wrote to this window's AI, in seconds since the epoch
     * (`recent-prompts.v1`); null when there is no AI, no conversation or no prompt yet.
     */
    val lastPromptAt: Long? = null,
)
