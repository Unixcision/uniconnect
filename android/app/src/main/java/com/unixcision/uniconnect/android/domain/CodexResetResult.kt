package com.unixcision.uniconnect.android.domain

/**
 * La respuesta de `mobile.accounts.codex_reset` (§5): para qué cuenta y host, qué dijo Codex
 * ([outcomeWire], crudo) y el uso de después, si lo dio. La pantalla vuelve a leer igualmente.
 */
data class CodexResetResult(val accountKey: String, val hostKey: String, val outcomeWire: String, val usage: AccountUsage?) {
    val outcome: CodexResetOutcome get() = CodexResetOutcome.named(outcomeWire)
}
