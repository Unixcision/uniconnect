package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cuándo se ofrece «Actualizar Claude» (`relaunch.v1.update`, 09-11-2026).
 *
 * Espacios y equipo enteros: con `relaunch.v1.update` a secas, y el plan excluye lo que no es
 * Claude. Una ventana suelta: además su celda `relaunch.v1.update.claude.<tipo>`, y que su IA sea
 * Claude o no se sepa. Ofrecerlo donde no se puede es un botón que siempre acaba en «no soportado».
 */
class RelaunchUpdateOfferTest {
    private fun snapshot(vararg capabilities: String) = MachineSnapshot("equipo", emptyList(), capabilities.toSet())

    private val linux = snapshot(
        MachineSnapshot.RELAUNCH, "relaunch.v1.claude.local", "relaunch.v1.claude.ssh", "relaunch.v1.codex.local",
        MachineSnapshot.UPDATE, "relaunch.v1.update.claude.local", "relaunch.v1.update.claude.ssh", MachineSnapshot.RESTORES,
    )
    private val soloLocal = snapshot(MachineSnapshot.RELAUNCH, "relaunch.v1.claude.local", MachineSnapshot.UPDATE, "relaunch.v1.update.claude.local")

    @Test fun `sin relaunch v1 update no se ofrece en ningun alcance`() {
        val antiguo = snapshot(MachineSnapshot.RELAUNCH, "relaunch.v1.claude.local")
        assertFalse(antiguo.updatesClaude)
        assertFalse(antiguo.updatesClaudeWindow(isSSH = false, provider = "claude"))
        // Y el token suelto, sin relaunch.v1, tampoco.
        assertFalse(snapshot(MachineSnapshot.UPDATE, "relaunch.v1.update.claude.local").updatesClaude)
    }

    @Test fun `espacio y equipo con el token a secas`() {
        assertTrue(linux.updatesClaude)
        assertTrue(soloLocal.updatesClaude)
        assertTrue(snapshot(MachineSnapshot.RELAUNCH, MachineSnapshot.UPDATE).updatesClaude)
    }

    @Test fun `una ventana necesita la celda de su tipo`() {
        assertTrue(soloLocal.updatesClaudeWindow(isSSH = false, provider = "claude"))
        assertFalse(soloLocal.updatesClaudeWindow(isSSH = true, provider = "claude"))
        // Sin saber el tipo, basta con alguna celda.
        assertTrue(soloLocal.updatesClaudeWindow(isSSH = null, provider = "claude"))
        // Sin ninguna celda, ni con el token general: el equipo no dijo dónde sabe hacerlo.
        assertFalse(snapshot(MachineSnapshot.RELAUNCH, MachineSnapshot.UPDATE).updatesClaudeWindow(isSSH = false, provider = "claude"))
    }

    @Test fun `solo Claude, o una ventana cuya IA no se sabe`() {
        assertTrue(linux.updatesClaudeWindow(isSSH = true, provider = "claude"))
        assertTrue(linux.updatesClaudeWindow(isSSH = true, provider = " Claude "))
        assertTrue(linux.updatesClaudeWindow(isSSH = true, provider = null))
        assertFalse(linux.updatesClaudeWindow(isSSH = false, provider = "codex"))
        assertFalse(linux.updatesClaudeWindow(isSSH = false, provider = "antigravity"))
    }

    @Test fun `los tokens de actualizar no se leen como celdas de relanzar`() {
        // `relaunch.v1.update.claude.local` no es «relanzar el proveedor update.claude».
        assertNull(RelaunchCell.parse("relaunch.v1.update.claude.local"))
        assertNull(RelaunchCell.parse(MachineSnapshot.UPDATE))
        assertNull(RelaunchCell.parse(MachineSnapshot.RESTORES))
        assertEquals(
            setOf(RelaunchCell("claude", "local"), RelaunchCell("claude", "ssh"), RelaunchCell("codex", "local")),
            linux.capabilities.mapNotNull(RelaunchCell::parse).toSet(),
        )
        // Y relanzar sigue mirando solo sus celdas: Codex en SSH no está anunciado.
        assertFalse(linux.relaunchesWindow(isSSH = true, provider = "codex"))
        assertTrue(linux.relaunchesWindow(isSSH = false, provider = "codex"))
    }
}
