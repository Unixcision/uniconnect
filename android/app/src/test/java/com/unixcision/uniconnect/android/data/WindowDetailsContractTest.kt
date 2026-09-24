package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.DetailsAgentState
import com.unixcision.uniconnect.android.domain.DetailsReason
import com.unixcision.uniconnect.android.domain.DetailsSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `mobile.terminal.details` tal como lo manda el equipo, por el decodificador de verdad.
 *
 * Los ficheros son los de `contracts/window-details-v1`, los mismos que leen el Mac y Linux: si el
 * contrato cambia y este lado no, se cae aquí.
 */
class WindowDetailsContractTest {
    private val client = NativeMachineClient(FramedRpcClient(CoroutineScope(Dispatchers.Unconfined)))

    private fun fixture(name: String): JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader?.getResourceAsStream("window-details-v1/$name"))
            { "falta el fixture del contrato: contracts/window-details-v1/$name" }
            .bufferedReader().readText()
    )

    @Test fun `una ventana local con Claude`() {
        val details = client.decodeDetails(fixture("details-response-local.json"))

        assertEquals("e86e9114-031c-4752-941d-1079c170a639", details.windowID)
        assertEquals("PROYECTOS", details.workspaceName)
        assertFalse(details.isSSH)
        // En local no hay destino: nulos, no «null» ni cadenas vacías disfrazadas.
        assertNull(details.host)
        assertNull(details.hostLabel)
        assertNull(details.hostDescription)
        assertEquals("MULTIGRAM-CLAUDE", details.windowName)

        val tmux = requireNotNull(details.tmux)
        assertEquals("uniconnect-local", tmux.socket)
        assertFalse(tmux.isDefaultServer)
        assertEquals("uc-e86e9114031c4752941d1079c170a639", tmux.session)
        assertEquals("\$12", tmux.sessionID)
        assertEquals("%14", tmux.paneID)
        assertTrue(tmux.live)

        val agent = requireNotNull(details.agent)
        assertEquals("claude", agent.provider)
        assertEquals("Claude Code", agent.name)
        assertEquals("714b0eae-b568-4e0c-a70b-c87c0d0a801a", agent.sessionID)
        assertEquals("/Users/danielgomezmartin/Desktop/PROYECTOS/MULTIGRAM", agent.cwd)
        assertEquals(false, agent.asRoot)
        assertEquals(DetailsSource.SESSION_FILE, agent.sourceKind)
        assertEquals(DetailsAgentState.ACTIVE, agent.stateKind)

        val resume = requireNotNull(agent.resume)
        assertEquals(
            listOf("claude", "--resume", "714b0eae-b568-4e0c-a70b-c87c0d0a801a", "--dangerously-skip-permissions"),
            resume.argv,
        )
        assertTrue(resume.environment.isEmpty())
        assertEquals(
            "cd -- '/Users/danielgomezmartin/Desktop/PROYECTOS/MULTIGRAM' && claude --resume 714b0eae-b568-4e0c-a70b-c87c0d0a801a --dangerously-skip-permissions",
            resume.command,
        )
        assertTrue(resume.noPromptVerified)
        assertNull(details.reason)
    }

    @Test fun `una ventana SSH con Claude como root lleva IS_SANDBOX`() {
        val details = client.decodeDetails(fixture("details-response-ssh.json"))

        assertTrue(details.isSSH)
        assertEquals("root@167.233.192.135:22", details.hostLabel)
        val host = requireNotNull(details.host)
        assertEquals("root", host.user)
        assertEquals("167.233.192.135", host.hostname)
        assertEquals(22, host.port)
        assertEquals("root@167.233.192.135:22", host.label)

        val tmux = requireNotNull(details.tmux)
        assertTrue(tmux.isDefaultServer)
        assertEquals("claudebets", tmux.session)
        assertEquals("\$0", tmux.sessionID)
        assertEquals("%0", tmux.paneID)
        assertTrue(tmux.live)

        val agent = requireNotNull(details.agent)
        assertEquals("473ed1de-4397-45ef-b00b-6b17fd7382b0", agent.sessionID)
        assertEquals(true, agent.asRoot)
        assertEquals("/root/xunis", agent.cwd)
        val resume = requireNotNull(agent.resume)
        assertEquals(mapOf("IS_SANDBOX" to "1"), resume.environment)
        assertEquals(
            "cd -- '/root/xunis' && IS_SANDBOX=1 claude --resume 473ed1de-4397-45ef-b00b-6b17fd7382b0 --dangerously-skip-permissions",
            resume.command,
        )
        assertNull(details.reason)
    }

    @Test fun `una ventana sin IA no inventa ninguna`() {
        val details = client.decodeDetails(fixture("details-response-no-agent.json"))

        assertEquals("hgabot", details.windowName)
        assertEquals("hgabot", details.tmux?.session)
        assertEquals(true, details.tmux?.live)
        assertNull(details.agent)
        assertEquals("sin_ia", details.reason)
        assertEquals(DetailsReason.NO_AGENT, details.reasonKind)
    }

    @Test fun `los null del contrato llegan como null y no como el texto null`() {
        // En Android, optString de un null de JSON devuelve "null". Una carpeta llamada «null» o un
        // identificador «null» se enseñarían como datos de verdad.
        val result = fixture("details-response-local.json")
        result.getJSONObject("tmux").put("session_id", JSONObject.NULL).put("pane_id", JSONObject.NULL).put("live", false)
        result.getJSONObject("agent").put("session_id", JSONObject.NULL).put("resume", JSONObject.NULL)
        result.put("reason", "sin_id")

        val details = client.decodeDetails(result)

        assertNull(details.tmux?.sessionID)
        assertNull(details.tmux?.paneID)
        assertEquals(false, details.tmux?.live)
        assertNull(details.agent?.sessionID)
        assertNull(details.agent?.resume)
        assertEquals(DetailsReason.NO_ID, details.reasonKind)
    }
}
