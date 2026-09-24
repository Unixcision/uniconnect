package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.RelaunchCause
import com.unixcision.uniconnect.android.domain.RelaunchTargetState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Las respuestas de `relaunch.apply` y `relaunch.status` del contrato, por el decodificador real.
 *
 * Lo que se vigila es `operation_state`: es el único campo que dice si la operación terminó.
 * `recovered` dice que ya existía, no que haya acabado, y confundirlos es enseñar «hecho» encima de
 * agentes que todavía se están cerrando.
 */
class RelaunchOperationContractTest {
    private val client = NativeMachineClient(FramedRpcClient(CoroutineScope(Dispatchers.Unconfined)))

    private fun fixture(name: String): JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader?.getResourceAsStream("relaunch-v1/$name"))
            { "falta el fixture del contrato: contracts/relaunch-v1/$name" }
            .bufferedReader().readText()
    )

    @Test fun `un apply en curso no ha terminado`() {
        val operation = client.decodeOperation(fixture("apply-in-progress-response.json"))

        assertEquals("en_curso", operation.operationState)
        assertFalse(operation.finished)
        assertFalse(operation.recovered)
        assertEquals(
            listOf(RelaunchTargetState.REOPENING, RelaunchTargetState.PLANNED),
            operation.results.map { it.state },
        )
    }

    @Test fun `un apply terminado dice su resultado por objetivo`() {
        val operation = client.decodeOperation(fixture("apply-response.json"))

        assertEquals("terminada", operation.operationState)
        assertTrue(operation.finished)
        assertEquals("bd3a3ea6-9f11-4c8e-b2a7-5d0e91c4f8aa", operation.results[0].effectiveID)
        assertEquals(RelaunchCause.FOLDER_TRUST, operation.results[1].cause)
        assertEquals(1, operation.needingUser.size)
    }

    @Test fun `recuperada y terminada son dos cosas distintas`() {
        val operation = client.decodeOperation(fixture("apply-recovered-response.json"))

        assertTrue(operation.recovered)
        assertEquals("terminada", operation.operationState)
        assertTrue(operation.finished)
    }

    @Test fun `sin operation_state deciden los objetivos`() {
        // Un equipo que no lo manda: con un objetivo todavía reabriendo, no ha terminado.
        val result = fixture("apply-in-progress-response.json").apply { remove("operation_state") }

        val operation = client.decodeOperation(result)

        assertEquals(null, operation.operationState)
        assertFalse(operation.finished)
    }
}
