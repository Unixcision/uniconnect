package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** El informe dice cómo están las cosas ahora: un fallo resuelto es historia, no un problema. */
class ConnectionHealthTest {
    private fun event(at: Long, machine: String, outcome: ConnectionEvent.Outcome, detail: String? = null) = ConnectionEvent(
        at = at, stage = "seguir", machine = machine, endpoint = "100.64.0.1:8855", outcome = outcome, millis = 7000, detail = detail,
    )
    private val ok = ConnectionEvent.Outcome.OK
    private val ko = ConnectionEvent.Outcome.ERROR_TRANSPORTE

    @Test
    fun aFailureFollowedBySuccessIsAResolvedIncidentAndNothingIsDown() {
        val health = ConnectionHealth.of(listOf(
            event(1_000, "MacBook", ko, "SocketTimeoutException"), event(2_000, "MacBook", ko), event(3_000, "MacBook", ok),
            event(3_500, "MINIPC", ok),
        ))
        assertTrue(health.healthy)
        val incident = health.incidents.single()
        assertEquals(2, incident.attempts.size)
        assertEquals(3_000L, incident.resolvedAt)
        val headline = DiagnosticReport.headline(health.let { listOf(
            event(1_000, "MacBook", ko, "SocketTimeoutException"), event(3_000, "MacBook", ok)) })
        assertTrue(headline, headline.startsWith("Todo bien ahora"))
        assertFalse(DiagnosticReport.isProblem(listOf(event(1_000, "MacBook", ko), event(3_000, "MacBook", ok))))
    }

    @Test
    fun aMachineWhoseLastAttemptsFailedIsDownSinceTheFirstOfTheRun() {
        val events = listOf(
            event(1_000, "MacBook", ok), event(5_000, "MacBook", ko), event(6_000, "MacBook", ko, "SocketTimeoutException"),
            event(6_500, "MINIPC", ok),
        )
        val health = ConnectionHealth.of(events)
        val down = health.down.single()
        assertEquals("MacBook", down.machine)
        assertEquals(5_000L, down.downSince)
        assertEquals(2, down.failing.size)
        assertNull(health.incidents.single().resolvedAt)
        val headline = DiagnosticReport.headline(events)
        assertTrue(headline, headline.startsWith("MacBook no responde") && headline.contains("2 fallos seguidos") && headline.contains("SocketTimeoutException"))
        assertTrue(DiagnosticReport.isProblem(events))
    }

    @Test
    fun aMachineTheAppHasConnectedNowIsNeverDownWhateverTheDiarySays() {
        val events = listOf(event(1_000, "MacBook", ko), event(2_000, "MacBook", ko))
        assertTrue(ConnectionHealth.of(events, connectedNow = setOf("MacBook")).healthy)
        assertFalse(DiagnosticReport.isProblem(events, connectedNow = setOf("MacBook")))
        assertTrue(DiagnosticReport.isProblem(events, connectedNow = setOf("MINIPC")))
    }

    @Test
    fun aCancelledAttemptNeitherBreaksNorStartsARun() {
        val cancelled = ConnectionEvent.Outcome.CANCELADO
        val health = ConnectionHealth.of(listOf(event(1_000, "MacBook", ok), event(2_000, "MacBook", cancelled)))
        assertTrue(health.healthy)
        assertTrue(health.incidents.isEmpty())
    }

    @Test
    fun theReportOpensWithThePresentAndKeepsTheFullLogBelow() {
        val events = listOf(event(1_000, "MacBook", ko, "SocketTimeoutException"), event(3_000, "MacBook", ok))
        val text = DiagnosticReport.render(environment = null, events = events, now = 4_000)
        assertTrue(text.contains("ESTADO AHORA: todo bien"))
        assertTrue(text.contains("MacBook: responde"))
        assertTrue(text.contains("resuelto a las"))
        assertTrue(text.contains("REGISTRO · últimos 2 intentos"))
        assertTrue(text.indexOf("ESTADO AHORA") < text.indexOf("REGISTRO"))
    }

    @Test
    fun aRejectedCreationNeverMakesAMachineLookDownButIsListedWithItsAnswer() {
        val events = listOf(
            event(1_000, "MacBook", ok),
            ConnectionEvent(at = 2_000, stage = "crear", machine = "MacBook", endpoint = "100.64.0.1:8855",
                outcome = ConnectionEvent.Outcome.RECHAZADO, millis = 40, detail = "create_failed"),
        )
        assertTrue(ConnectionHealth.of(events).healthy)
        assertFalse(DiagnosticReport.isProblem(events))
        val text = DiagnosticReport.render(environment = null, events = events, now = 3_000)
        assertTrue(text.contains("ACCIONES QUE FALLARON"))
        assertTrue(text.contains("crear: rechazado · create_failed"))
    }
}
