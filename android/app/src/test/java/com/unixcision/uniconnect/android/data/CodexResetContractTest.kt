package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.CodexResetOutcome
import com.unixcision.uniconnect.android.domain.ResetCredits
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.time.Instant

/** La llamada `mobile.accounts.codex_reset` (§5): sus parámetros y su respuesta, con y sin uso. */
class CodexResetContractTest {
    private val client = NativeMachineClient(FramedRpcClient(CoroutineScope(Dispatchers.Unconfined)))
    private val account = "codex:ana@ejemplo.com"

    @Test fun `viajan la cuenta, el host y la clave, y nada mas`() {
        val params = client.codexResetParameters(account, "ssh:root@203.0.113.10:22", "5f0c8a52-6e1d-4a3b-9c2f-7d8e1b4a6c90")
        assertEquals(setOf("account_key", "host_key", "idempotency_key"), params.keys().asSequence().toSet())
        assertEquals(account, params.getString("account_key"))
        assertEquals("ssh:root@203.0.113.10:22", params.getString("host_key"))
        assertEquals("5f0c8a52-6e1d-4a3b-9c2f-7d8e1b4a6c90", params.getString("idempotency_key"))
    }

    @Test fun `sin cuenta, host o clave no sale`() {
        assertThrows(IllegalArgumentException::class.java) { client.codexResetParameters("", "local", "k") }
        assertThrows(IllegalArgumentException::class.java) { client.codexResetParameters(account, " ", "k") }
        assertThrows(IllegalArgumentException::class.java) { client.codexResetParameters(account, "local", "") }
    }

    @Test fun `la respuesta trae el outcome y el uso de despues`() {
        val usage = JSONObject()
            .put("source", "app_server").put("observed_at", "2026-11-10T12:31:00Z")
            .put("limits", JSONArray().put(JSONObject().put("id", "primary").put("used_percent", 0.0).put("resets_at", "2026-11-17T12:31:00Z").put("window_minutes", 10_080)))
            .put("reset_credits", JSONObject().put("available", 1).put("next_expires_at", "2026-11-30T20:02:00Z"))
        val result = client.decodeCodexReset(JSONObject().put("account_key", account).put("host_key", "local").put("outcome", "reset").put("usage", usage))

        assertEquals(account, result.accountKey)
        assertEquals("local", result.hostKey)
        assertEquals(CodexResetOutcome.RESET, result.outcome)
        assertEquals(0.0, requireNotNull(result.usage).limits.single().usedPercent, 0.0)
        assertEquals(ResetCredits(1, Instant.parse("2026-11-30T20:02:00Z")), result.usage?.resetCredits)
    }

    @Test fun `sin uso de despues, y un outcome que se reconoce igual`() {
        val result = client.decodeCodexReset(
            JSONObject().put("account_key", account).put("host_key", "local").put("outcome", "alreadyRedeemed").put("usage", JSONObject.NULL),
        )
        assertEquals(CodexResetOutcome.ALREADY_REDEEMED, result.outcome)
        assertNull(result.usage)
    }
}
