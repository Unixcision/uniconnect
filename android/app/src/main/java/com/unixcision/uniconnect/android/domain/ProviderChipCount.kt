package com.unixcision.uniconnect.android.domain

/**
 * Una ficha del filtro por IA: «Todas las IA · 56», «Claude Code · 44», «Codex · 8»…
 *
 * [provider] es el `agent.provider` (`claude`, `codex`, `grok`…) o nulo en «Todas las IA», y
 * [displayName] su nombre tal como lo da el equipo. No hay lista fija: salen las IA de la lectura.
 */
data class ProviderChipCount(val provider: String?, val displayName: String?, val count: Int)
