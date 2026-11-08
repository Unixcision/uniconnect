package com.unixcision.uniconnect.android.domain

/** The name a person reads for a host's agent token: `claude` is Claude, `agy` is Antigravity. */
object AgentLabel {
    private val known = mapOf(
        "claude" to "Claude", "codex" to "Codex", "agy" to "Antigravity", "antigravity" to "Antigravity",
        "gemini" to "Gemini", "opencode" to "OpenCode", "cursor" to "Cursor", "aider" to "Aider", "amp" to "Amp",
    )

    /** The label of [raw], or null when the window has no AI. */
    fun of(raw: String?): String? {
        val token = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return known[token.lowercase()] ?: token.replaceFirstChar { it.uppercase() }
    }
}
