package com.unixcision.uniconnect.android.domain

/**
 * Una cuenta de Codex a la que se le puede gastar un reseteo gratis, y a qué equipo y host pedírselo.
 *
 * [hostKey] es el `usage.host_key` de la cuenta: el host donde se vio el uso que dice que hay
 * reseteos. [available] es cuántos quedan, para la confirmación.
 */
data class CodexResetTarget(
    val machineID: String,
    val accountKey: String,
    val hostKey: String,
    val email: String,
    val available: Int,
) {
    companion object {
        /**
         * El reseteo que se puede ofrecer en [account], o nulo si no se ofrece.
         *
         * Solo en Codex, con `reset_credits.available > 0`, sabiendo en qué host se vio el uso y si
         * el equipo donde se vio está en [capableMachines] (los que anuncian
         * `accounts.codex_reset.v1`). Sin cualquiera de esas cosas, el botón no sale.
         */
        fun of(account: UsageAccount, capableMachines: Set<String>): CodexResetTarget? {
            if (account.provider != CODEX) return null
            val usage = account.usage ?: return null
            val available = usage.resetCredits?.available?.takeIf { it > 0 } ?: return null
            val hostKey = usage.hostKey?.takeIf { it.isNotBlank() } ?: return null
            val machineID = account.usageMachineID?.takeIf { it in capableMachines } ?: return null
            val email = account.email ?: return null
            return CodexResetTarget(machineID, account.key, hostKey, email, available)
        }

        private const val CODEX = "codex"
    }
}
