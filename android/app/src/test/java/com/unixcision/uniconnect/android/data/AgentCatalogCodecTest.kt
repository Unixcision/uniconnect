package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentCatalogCodecTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val client = NativeMachineClient(FramedRpcClient(scope))
    private val machine = Machine("machine", "Equipo", requireNotNull(MachineEndpoint.parse("100.64.0.1", "58465")))

    @After fun tearDown() { scope.cancel() }

    @Test fun workspaceDecoderPreservesTheHostCatalogIncludingOpaqueCustomIds() {
        val snapshot = decode(JSONObject("""{"workspaces":[{"id":"local","title":"Proyecto","kind":"local","terminals":[],"available_agent_targets":[{"id":"terminal","title":"Terminal"},{"id":"custom:review-team","title":"Revisión del equipo"}]},{"id":"ssh","title":"Servidor","kind":"ssh","terminals":[],"available_agent_targets":[{"id":"terminal","title":"Terminal"}]}]}"""))
        assertEquals(listOf("terminal", "custom:review-team"), snapshot.workspaces[0].availableAgentTargets.map { it.id })
        assertEquals("Revisión del equipo", snapshot.workspaces[0].availableAgentTargets[1].title)
        assertEquals(listOf("terminal"), snapshot.workspaces[1].availableAgentTargets.map { it.id })
    }

    @Test fun absentHostCatalogDoesNotAdvertiseInventedAgentChoices() {
        val snapshot = decode(JSONObject("""{"workspaces":[{"id":"local","title":"Proyecto","kind":"local","terminals":[]}]}"""))
        assertTrue(snapshot.workspaces.single().availableAgentTargets.isEmpty())
    }

    @Test fun sharedCreationEncoderSendsOnlyTheChosenIdAndExplicitWindowConfiguration() {
        val local = client.creationParameters(ResourceCreation.Terminal("local", "Revisión", "/proyecto", null, "custom:review-team"))
        assertEquals("custom:review-team", local.getString("agent"))
        assertEquals("local", local.getString("workspace_id"))
        assertEquals("/proyecto", local.getString("directory"))
        assertEquals(setOf("name", "directory", "workspace_id", "agent"), local.keys().asSequence().toSet())
        val ssh = client.creationParameters(ResourceCreation.Terminal("ssh", "Consola", null, "app4"))
        assertEquals("terminal", ssh.getString("agent"))
        assertEquals("app4", ssh.getString("tmux_session"))
        assertFalse(ssh.has("directory"))
        assertEquals(setOf("name", "workspace_id", "agent", "tmux_session"), ssh.keys().asSequence().toSet())
    }

    private fun decode(value: JSONObject): MachineSnapshot = NativeMachineClient::class.java
        .getDeclaredMethod("decodeMachine", Machine::class.java, JSONObject::class.java)
        .apply { isAccessible = true }.invoke(client, machine, value) as MachineSnapshot

    @Test fun aWrittenConnectionTravelsAsSshWithItsCommandAndNothingElse() {
        val written = client.creationParameters(
            ResourceCreation.Workspace("ELTEMPLO", null, null, initialTerminal = false, connectCommand = "ssh root@eltemploacademy.com")
        )
        assertEquals("ssh", written.getString("kind"))
        assertEquals("ssh root@eltemploacademy.com", written.getString("connect_command"))
        assertFalse("a written command inherits nothing", written.has("source_workspace_id"))
        assertFalse(written.getBoolean("initial_terminal"))

        val inherited = client.creationParameters(ResourceCreation.Workspace("Otra", null, "caja-origen"))
        assertEquals("ssh", inherited.getString("kind"))
        assertEquals("caja-origen", inherited.getString("source_workspace_id"))
        assertFalse("inheriting sends no command", inherited.has("connect_command"))

        val local = client.creationParameters(ResourceCreation.Workspace("Proyecto", "/home/dani", null))
        assertEquals("local", local.getString("kind"))
        assertFalse(local.has("connect_command"))
    }

    @Test fun `el alcance viaja con kind e id, y nada mas`() {
        // Acordado con el motor Linux: el espacio al que pertenece una ventana se queda en el
        // modelo. Mandarlo por el cable invitaria a que el equipo resolviera el objetivo con el, y
        // quien puede resolverlo es el que lo tiene delante.
        val ventana = client.scopeParameters(RelaunchScope.Window("maquina", "espacio", "ventana-7"))
        assertEquals("window", ventana.getString("kind"))
        assertEquals("ventana-7", ventana.getString("id"))
        assertFalse(ventana.has("workspace_id"))
        assertEquals(2, ventana.length())

        val espacio = client.scopeParameters(RelaunchScope.Workspace("maquina", "espacio-3"))
        assertEquals("workspace", espacio.getString("kind"))
        assertEquals("espacio-3", espacio.getString("id"))

        val equipo = client.scopeParameters(RelaunchScope.Machine("maquina-1"))
        assertEquals("machine", equipo.getString("kind"))
        assertEquals("maquina-1", equipo.getString("id"))
    }
}
