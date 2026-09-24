package com.unixcision.uniconnect.android.domain

/**
 * One `relaunch.v1.<provider>.<kind>` token: an agent a host can relaunch in one kind of window.
 *
 * Hosts after D7 (24-09-2026) announce them next to `relaunch.v1`; the exact list of each host is its
 * row of `capacidades` in `contracts/relaunch-v1/proveedores.json`. [provider] is the canonical wire
 * id (`claude`, `codex`, `agy`, `grok`, …) and [kind] is [LOCAL] or [SSH].
 */
data class RelaunchCell(val provider: String, val kind: String) {
    companion object {
        const val LOCAL = "local"
        const val SSH = "ssh"
        private const val PREFIX = "relaunch.v1."

        /** The cell a capability names, or null when it is not a `relaunch.v1.<provider>.<kind>` token. */
        fun parse(token: String): RelaunchCell? {
            if (!token.startsWith(PREFIX)) return null
            val rest = token.removePrefix(PREFIX)
            val kind = rest.substringAfterLast('.', "")
            val provider = rest.substringBeforeLast('.', "")
            if ((kind != LOCAL && kind != SSH) || provider.isEmpty() || '.' in provider) return null
            return RelaunchCell(provider, kind)
        }
    }
}
