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
}
