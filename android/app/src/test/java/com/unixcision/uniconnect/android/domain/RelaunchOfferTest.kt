package com.unixcision.uniconnect.android.domain

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cuándo se ofrece «Relanzar IA de esta ventana» (`contracts/relaunch-v1`, D7).
 *
 * Tras D7 el Mac relanza Claude y Codex en ventanas locales y nada por SSH, y Linux las dos IA en
 * local y en SSH. Cada equipo lo anuncia con `relaunch.v1.<proveedor>.<tipo>`. Ofrecer la entrada
 * donde el equipo no sabe hacerlo es enseñar un botón que siempre acaba en «no soportado».
 */
class RelaunchOfferTest {
    private val matrix: JSONObject by lazy {
        JSONObject(
            requireNotNull(javaClass.classLoader?.getResourceAsStream("relaunch-v1/proveedores.json")) {
                "falta contracts/relaunch-v1/proveedores.json"
            }.bufferedReader().readText()
        )
    }

    private fun snapshot(capabilities: Collection<String>) = MachineSnapshot("equipo", emptyList(), capabilities.toSet())

    private fun JSONArray.strings(): List<String> = List(length()) { getString(it) }

    @Test fun `cada equipo ofrece exactamente su fila de la matriz`() {
        val equipos = matrix.getJSONObject("equipos")
        val capacidades = matrix.getJSONObject("capacidades")
        val noSoportado = matrix.getJSONObject("no_soportado")
        assertTrue(equipos.length() >= 2)
        for (equipo in equipos.keys()) {
            val host = snapshot(capacidades.getJSONArray(equipo).strings())
            for ((tipo, isSSH) in listOf("local" to false, "ssh" to true)) {
                for (provider in equipos.getJSONObject(equipo).getJSONArray(tipo).strings()) {
                    assertTrue("$equipo $tipo $provider", host.relaunchesWindow(isSSH, provider))
                }
                for (provider in noSoportado.getJSONObject(equipo).getJSONArray(tipo).strings().filter { it != "otros" }) {
                    assertFalse("$equipo $tipo $provider", host.relaunchesWindow(isSSH, provider))
                }
            }
        }
    }

    @Test fun `el Mac no ofrece relanzar una ventana SSH ni sabiendo su IA ni sin saberla`() {
        val mac = snapshot(matrix.getJSONObject("capacidades").getJSONArray("macos").strings())
        assertFalse(mac.relaunchesWindow(isSSH = true, provider = "claude"))
        assertFalse(mac.relaunchesWindow(isSSH = true, provider = null))
        // En local, sin saber qué IA corre, se ofrece: hay alguna de ese tipo y el plan decide.
        assertTrue(mac.relaunchesWindow(isSSH = false, provider = null))
        assertFalse(mac.relaunchesWindow(isSSH = false, provider = "gemini"))
    }

    @Test fun `un equipo anterior a D7 lo ofrece como siempre y deja que el plan excluya`() {
        val antiguo = snapshot(listOf(MachineSnapshot.RELAUNCH, MachineSnapshot.WINDOW_DETAILS))
        assertTrue(antiguo.relaunchesWindow(isSSH = true, provider = "grok"))
        assertTrue(antiguo.relaunchesWindow(isSSH = null, provider = null))
    }

    @Test fun `sin relaunch v1 no se ofrece aunque vengan tokens sueltos`() {
        assertFalse(snapshot(listOf("relaunch.v1.claude.local")).relaunchesWindow(isSSH = false, provider = "claude"))
    }

    @Test fun `el nombre del catalogo de Antigravity cuenta como agy`() {
        val host = snapshot(listOf(MachineSnapshot.RELAUNCH, "relaunch.v1.agy.local"))
        assertTrue(host.relaunchesWindow(isSSH = false, provider = "antigravity"))
        assertTrue(host.relaunchesWindow(isSSH = false, provider = "AGY"))
    }

    @Test fun `solo se leen los tokens bien formados`() {
        assertEquals(RelaunchCell("claude", "local"), RelaunchCell.parse("relaunch.v1.claude.local"))
        assertEquals(RelaunchCell("hermes-agent", "ssh"), RelaunchCell.parse("relaunch.v1.hermes-agent.ssh"))
        assertNull(RelaunchCell.parse("relaunch.v1"))
        assertNull(RelaunchCell.parse("relaunch.v1.claude"))
        assertNull(RelaunchCell.parse("relaunch.v1.claude.movil"))
        assertNull(RelaunchCell.parse("relaunch.v1..local"))
        assertNull(RelaunchCell.parse("relaunch.v2.claude.local"))
    }
}
