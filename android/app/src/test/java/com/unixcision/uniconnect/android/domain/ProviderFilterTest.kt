package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * El filtro y la agrupación por IA con datos hechos a mano: sin lista fija de IAs, desempates
 * estables y una IA elegida que desaparece de la lectura; y los números con coma decimal.
 */
class ProviderFilterTest {
    private fun window(id: String, provider: String?, name: String = provider ?: "") = AccountWindow(
        "ws", "ESPACIO", id, "v$id", "local", "uc-$id", if (provider == null) "sesion_no_viva" else "ok",
        provider?.let { AccountAgent(it, name, false) }, null,
    )

    private fun board(vararg windows: AccountWindow) = AccountsBoard(listOf(
        MachineAccounts("mac", "Mac", AccountsReport(1, "2026-11-10T12:30:06Z", emptyList(), windows.toList())),
    ))

    @Test fun `cualquier IA que aparezca sale sola, y a igualdad por su id`() {
        val board = board(window("1", "grok", "Grok"), window("2", "hermes", "Hermes"), window("3", "grok", "Grok"), window("4", "codex", "Codex"), window("5", null))
        assertEquals(
            listOf(
                ProviderChipCount(null, null, 4), ProviderChipCount("grok", "Grok", 2),
                ProviderChipCount("codex", "Codex", 1), ProviderChipCount("hermes", "Hermes", 1),
            ),
            board.providerChips(AccountsQuery()),
        )
        assertEquals(
            listOf(AccountGroup.Key.Agent("grok", "Grok"), AccountGroup.Key.Agent("codex", "Codex"), AccountGroup.Key.Agent("hermes", "Hermes"), AccountGroup.Key.NoAgent),
            board.groups(AccountsQuery(grouping = AccountsQuery.Grouping.BY_AGENT)).map { it.key },
        )
    }

    @Test fun `una IA elegida que ya no esta sigue con un cero para poder quitarla`() {
        val board = board(window("1", "claude", "Claude Code"))
        val query = AccountsQuery(provider = "codex")
        assertEquals(ProviderChipCount("codex", "codex", 0), board.providerChips(query).last())
        assertEquals(emptyList<AccountRow>(), board.filtered(query))
    }

    @Test fun `el ritmo y los porcentajes con coma decimal`() {
        assertEquals("113,7", UsageNumbers.oneDecimal(113.66))
        assertEquals("17,5", UsageNumbers.oneDecimal(17.4549))
        assertEquals("-2,0", UsageNumbers.oneDecimal(-2.0))
        assertEquals("51 %", UsageNumbers.percent(51.0))
        assertEquals("3,5 %", UsageNumbers.percent(3.5))
        assertEquals("100 %", UsageNumbers.percent(99.96))
        assertEquals("0 %", UsageNumbers.percent(0.0))
    }
}
