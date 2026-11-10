package com.unixcision.uniconnect.android.domain

import java.time.Instant

/**
 * Lo último que una IA dijo de sus límites (`usage`), con la hora en que lo dijo.
 *
 * [source] es `statusline` (Claude) o `rollout` (Codex). [hostKey] solo viene en `accounts[]`: el
 * host donde se vio ese uso.
 */
data class AccountUsage(
    val source: String?,
    val observedAt: Instant?,
    val limits: List<UsageLimit>,
    val hostKey: String? = null,
)
