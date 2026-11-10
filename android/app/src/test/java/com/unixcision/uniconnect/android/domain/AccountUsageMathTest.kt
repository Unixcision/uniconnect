package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.DayOfWeek
import java.time.Duration
import java.time.Instant
import java.time.ZoneId

/**
 * Las reglas de «Uso por cuenta» (§4.1) con una hora fija: lo que se pinta de cada límite, cuándo
 * un dato es viejo, y el ritmo y la proyección con la fórmula común a las tres plataformas.
 */
class AccountUsageMathTest {
    private val now = Instant.parse("2026-11-10T12:30:06Z")
    private val madrid = ZoneId.of("Europe/Madrid")
    private val math = AccountUsageMath(now, madrid)

    private fun at(iso: String) = Instant.parse(iso)
    private fun week(percent: Double, resets: String = "2026-11-15T14:00:00Z") = UsageLimit("seven_day", percent, at(resets), 10_080)
    private fun sample(iso: String, value: Double, id: String = "seven_day") = UsageSample(at(iso), mapOf(id to value))

    @Test fun `cada limite con su nombre, y Codex por su ventana`() {
        assertEquals(LimitName.FiveHours, LimitName.of("five_hour", 300))
        assertEquals(LimitName.Week, LimitName.of("seven_day", 10_080))
        assertEquals(LimitName.WeekOpus, LimitName.of("seven_day_opus", 10_080))
        assertEquals(LimitName.WeekSonnet, LimitName.of("seven_day_sonnet", null))
        assertEquals(LimitName.WeekFable, LimitName.of("seven_day_fable", null))
        assertEquals(LimitName.FiveHours, LimitName.of("primary", 300))
        assertEquals(LimitName.Week, LimitName.of("secondary", 10_080))
        assertEquals(LimitName.Hours(2), LimitName.of("primary", 120))
        assertEquals(LimitName.Hours(1), LimitName.of("primary", 30))
        assertEquals(LimitName.Raw("otro"), LimitName.of("otro", null))
        assertEquals(LimitName.Raw("otro"), LimitName.of("otro", 0))
    }

    @Test fun `si el reset ya paso, 0 por ciento y reseteado`() {
        assertEquals(AccountUsageMath.Reading(51.0, wasReset = false), math.reading(week(51.0)))
        assertEquals(AccountUsageMath.Reading(0.0, wasReset = true), math.reading(week(97.0, resets = "2026-11-10T12:00:00Z")))
        // Justo en el instante del reset ya cuenta como reseteado.
        assertTrue(math.reading(week(97.0, resets = "2026-11-10T12:30:06Z")).wasReset)
        // Sin hora de reset no se adivina: se pinta lo que dijo.
        assertEquals(42.0, math.reading(UsageLimit("primary", 42.0, null, null)).percent, 0.0)
    }

    @Test fun `un dato de mas de una hora es viejo`() {
        assertFalse(math.isOld(now.minusSeconds(3_600)))
        assertTrue(math.isOld(now.minusSeconds(3_601)))
        assertFalse(math.isOld(now.plusSeconds(30)))
    }

    @Test fun `lo que falta para el reset y la antiguedad, nunca en negativo`() {
        assertEquals(AccountUsageMath.Span(5, 1, 29), math.remaining(at("2026-11-15T14:00:00Z")))
        assertEquals(AccountUsageMath.Span(0, 1, 59), math.remaining(at("2026-11-10T14:30:00Z")))
        assertEquals(AccountUsageMath.Span(0, 0, 12), math.remaining(now.plus(Duration.ofMinutes(12))))
        assertEquals(AccountUsageMath.Span(0, 0, 0), math.remaining(now.minusSeconds(600)))
        assertEquals(AccountUsageMath.Age(8, AccountUsageMath.Age.Unit.SECONDS), math.age(at("2026-11-10T12:29:58Z")))
        assertEquals(AccountUsageMath.Age(17, AccountUsageMath.Age.Unit.MINUTES), math.age(at("2026-11-10T12:12:40Z")))
        assertEquals(AccountUsageMath.Age(18, AccountUsageMath.Age.Unit.HOURS), math.age(at("2026-11-09T17:53:22Z")))
        assertEquals(AccountUsageMath.Age(2, AccountUsageMath.Age.Unit.DAYS), math.age(at("2026-11-08T09:00:00Z")))
        assertEquals(AccountUsageMath.Age(0, AccountUsageMath.Age.Unit.SECONDS), math.age(now.plusSeconds(5)))
    }

    @Test fun `la hora local del reset es la de Madrid`() {
        // 14:00 UTC en noviembre son las 15:00 en Madrid (CET).
        val sunday = math.local(at("2026-11-15T14:00:00Z"))
        assertEquals(DayOfWeek.SUNDAY, sunday.dayOfWeek)
        assertEquals(15, sunday.hour)
        assertEquals(0, sunday.minute)
        assertEquals(DayOfWeek.SATURDAY, math.local(at("2026-11-14T14:00:00Z")).dayOfWeek)
    }

    @Test fun `ritmo y proyeccion de la semana del contrato, con agotamiento antes del reset`() {
        // Las muestras semanales de la primera cuenta de accounts-response.json, todas en la ventana.
        val history = listOf(
            sample("2026-11-09T09:00:00Z", 31.0), sample("2026-11-09T21:00:00Z", 42.0),
            UsageSample(at("2026-11-10T08:00:00Z"), mapOf("seven_day" to 47.0, "five_hour" to 0.0)),
            UsageSample(at("2026-11-10T12:29:58Z"), mapOf("seven_day" to 51.0, "five_hour" to 3.5)),
        )
        val projection = requireNotNull(math.projection(week(51.0), at("2026-11-10T12:29:58Z"), history))
        // (51 − 31) puntos en 27,49944 h.
        assertEquals(17.4549, projection.perDay, 1e-3)
        assertEquals(139.364, projection.atReset, 1e-2)
        val exhaustion = requireNotNull(projection.exhaustion)
        assertEquals(at("2026-11-13T07:52:31Z").epochSecond.toDouble(), exhaustion.epochSecond.toDouble(), 2.0)
        assertTrue(exhaustion.isBefore(at("2026-11-15T14:00:00Z")))
    }

    @Test fun `por debajo de 100 no hay agotamiento, solo proyeccion`() {
        val history = listOf(sample("2026-11-10T06:00:00Z", 40.0))
        val projection = requireNotNull(math.projection(week(42.0), at("2026-11-10T12:00:00Z"), history))
        // 2 puntos en 6 h: 8 al día; quedan 121,4983 h hasta el reset.
        assertEquals(8.0, projection.perDay, 1e-6)
        assertEquals(42.0 + 2.0 / 6.0 * 121.4983, projection.atReset, 1e-2)
        assertNull(projection.exhaustion)
    }

    @Test fun `hacen falta dos muestras separadas al menos 30 minutos y dentro de la ventana`() {
        // Una sola muestra: la actual coincide con la del histórico.
        assertNull(math.projection(week(51.0), at("2026-11-10T12:29:58Z"), listOf(sample("2026-11-10T12:29:58Z", 51.0))))
        // Dos, a 29 min.
        assertNull(math.projection(week(51.0), at("2026-11-10T12:29:00Z"), listOf(sample("2026-11-10T12:00:00Z", 50.0))))
        // Exactamente 30 min sí vale.
        assertNotNull(math.projection(week(51.0), at("2026-11-10T12:30:00Z"), listOf(sample("2026-11-10T12:00:00Z", 50.0))))
        // La muestra vieja es de antes de la ventana actual (empezó el 08-11 a las 14:00): no cuenta.
        assertNull(math.projection(week(51.0), at("2026-11-10T12:29:58Z"), listOf(sample("2026-11-08T13:00:00Z", 90.0))))
        // La de otro límite tampoco.
        assertNull(math.projection(week(51.0), at("2026-11-10T12:29:58Z"), listOf(sample("2026-11-09T09:00:00Z", 31.0, id = "five_hour"))))
    }

    @Test fun `sin reset por delante o sin ventana no se proyecta`() {
        val history = listOf(sample("2026-11-09T09:00:00Z", 31.0))
        assertNull(math.projection(week(51.0, resets = "2026-11-10T12:00:00Z"), at("2026-11-10T11:00:00Z"), history))
        assertNull(math.projection(UsageLimit("seven_day", 51.0, at("2026-11-15T14:00:00Z"), null), at("2026-11-10T12:29:58Z"), history))
        assertNull(math.projection(UsageLimit("seven_day", 51.0, null, 10_080), at("2026-11-10T12:29:58Z"), history))
    }

    @Test fun `un ritmo que baja no se agota`() {
        val projection = requireNotNull(math.projection(week(30.0), at("2026-11-10T12:00:00Z"), listOf(sample("2026-11-10T06:00:00Z", 40.0))))
        assertTrue(projection.perDay < 0)
        assertNull(projection.exhaustion)
    }
}
