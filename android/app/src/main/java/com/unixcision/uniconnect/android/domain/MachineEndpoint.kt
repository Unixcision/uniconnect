package com.unixcision.uniconnect.android.domain

/** Pure validation: parsing an address never resolves DNS or opens a socket. */
@ConsistentCopyVisibility
data class MachineEndpoint private constructor(val host: String, val port: Int) {
    val displayAddress: String get() = if (':' in host) "[$host]:$port" else "$host:$port"

    companion object {
        const val DEFAULT_PORT = 58465

        fun parse(address: String, portText: String): MachineEndpoint? {
            val port = portText.trim().toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val host = address.trim().removeSurrounding("[", "]").lowercase()
            if (host.length !in 1..253) return null
            val valid = when {
                ':' in host -> isTailnetIPv6(host)
                host.all { it.isDigit() || it == '.' } -> isTailnetIPv4(host)
                else -> isMagicDNS(host)
            }
            return if (valid) MachineEndpoint(host, port) else null
        }

        private fun isTailnetIPv4(host: String): Boolean {
            val parts = host.split('.')
            if (parts.size != 4 || parts.any { it.isEmpty() || it.length > 3 || (it.length > 1 && it[0] == '0') }) return false
            val octets = parts.map { it.toIntOrNull() ?: return false }
            return octets.all { it in 0..255 } && octets[0] == 100 && octets[1] in 64..127
        }

        private fun isTailnetIPv6(host: String): Boolean {
            if (!host.startsWith("fd7a:115c:a1e0:") || host.any { it !in "0123456789abcdef:" }) return false
            if (host.endsWith(':') && !host.endsWith("::")) return false
            if (host.windowed(2).count { it == "::" } > 1) return false
            val groups = host.split(':').filter { it.isNotEmpty() }
            if (groups.any { it.length > 4 }) return false
            return if ("::" in host) groups.size in 3..7 else groups.size == 8
        }

        private fun isMagicDNS(host: String): Boolean {
            val label = Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
            val parts = host.split('.')
            if (parts.any { !label.matches(it) }) return false
            return parts.size == 1 || (parts.size >= 3 && host.endsWith(".ts.net"))
        }
    }
}
