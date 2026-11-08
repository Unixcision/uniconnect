package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineEndpoint
import com.unixcision.uniconnect.android.domain.MachineSnapshot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A window with no AI comes with `"agent": null`; the phone must read nothing, not the text "null". */
class WorkspaceListDecodeTest {
    private val client = NativeMachineClient(FramedRpcClient(CoroutineScope(Dispatchers.Unconfined)))
    private val machine = Machine("mac", "Mac", MachineEndpoint.parse("100.64.0.1", "8855")!!)

    // Same route as AgentCatalogCodecTest: the decoder stays private to the client.
    private fun decode(value: JSONObject): MachineSnapshot = NativeMachineClient::class.java
        .getDeclaredMethod("decodeMachine", Machine::class.java, JSONObject::class.java)
        .apply { isAccessible = true }.invoke(client, machine, value) as MachineSnapshot

    @Test
    fun aJsonNullAgentOrSourceIsNoAgentAtAll() {
        val result = JSONObject(
            """
            {"workspaces":[{"id":"w","title":"IBERIAVO-PREPRO","kind":"ssh","terminals":[
              {"id":"a","title":"CHATBOT","activity":{"state":"idle","source":null,"agent":null,"since":null}},
              {"id":"b","title":"CODEX","activity":{"state":"working","source":"hooks","agent":"codex","since":1800000000}}
            ]}]}
            """.trimIndent(),
        )
        val windows = decode(result).workspaces.single().windows
        assertNull(windows[0].activity?.agent)
        assertNull(windows[0].activity?.source)
        assertNull(windows[0].activity?.sinceEpochSeconds)
        assertEquals(ActivityState.IDLE, windows[0].activity?.state)
        assertEquals("codex", windows[1].activity?.agent)
        assertEquals(1_800_000_000L, windows[1].activity?.sinceEpochSeconds)
    }
}
