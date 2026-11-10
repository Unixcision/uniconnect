package com.unixcision.uniconnect.android.domain

import java.time.Duration
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * Las reglas de «Uso por cuenta» (`accounts.v1` §4.1) en un instante: qué porcentaje se pinta,
 * cuánto falta para el reset, qué antigüedad tiene un dato, y ritmo y proyección. Las mismas
 * fórmulas que el Mac y Linux.
 *
 * [now] y [zone] se inyectan: nada de aquí mira el reloj, así que las pruebas fijan la hora.
 */
class AccountUsageMath(private val now: Instant, private val zone: ZoneId) {
    /** Lo que se pinta de un límite ahora. [wasReset]: su ventana reseteó después de observarlo. */
    data class Reading(val percent: Double, val wasReset: Boolean)

    /**
     * Ritmo y proyección de un límite dentro de su ventana actual.
     *
     * @property perDay puntos por día.
     * @property atReset dónde estaría al llegar a `resets_at` a este ritmo (puede pasar de 100).
     * @property exhaustion cuándo llegaría a 100 %, si llega antes del reset.
     */
    data class Projection(val perDay: Double, val atReset: Double, val exhaustion: Instant?)

    /** Lo que falta para algo, en días, horas y minutos enteros. */
    data class Span(val days: Long, val hours: Long, val minutes: Long)

    /** La antigüedad de un dato en la unidad que se lee mejor. */
    data class Age(val value: Long, val unit: Unit) {
        enum class Unit { SECONDS, MINUTES, HOURS, DAYS }
    }

    /** El porcentaje de ahora: 0 si la ventana ya reseteó desde que se observó. */
    fun reading(limit: UsageLimit): Reading {
        val resetsAt = limit.resetsAt
        return if (resetsAt != null && !resetsAt.isAfter(now)) Reading(0.0, wasReset = true)
        else Reading(limit.usedPercent, wasReset = false)
    }

    /** Si un dato tiene más de una hora: se pinta en ámbar. */
    fun isOld(observedAt: Instant): Boolean = Duration.between(observedAt, now).seconds > OLD_SECONDS

    /**
     * Ritmo y proyección de [limit] (§4.1), o nulo si no se pueden dar.
     *
     * Usa las muestras de [history] de ese límite dentro de la ventana actual
     * (`at >= resets_at - window_minutes`) más el uso actual, observado en [observedAt]. Hacen falta
     * `resets_at` por delante, `window_minutes` y dos muestras separadas 30 min o más.
     */
    fun projection(limit: UsageLimit, observedAt: Instant?, history: List<UsageSample>): Projection? {
        val resetsAt = limit.resetsAt?.takeIf { it.isAfter(now) } ?: return null
        val windowMinutes = limit.windowMinutes?.takeIf { it > 0 } ?: return null
        val windowStart = resetsAt.minus(Duration.ofMinutes(windowMinutes.toLong()))
        val samples = history.mapNotNull { sample ->
            val value = sample.limits[limit.id] ?: return@mapNotNull null
            if (sample.at.isBefore(windowStart)) null else sample.at to value
        }.toMutableList()
        if (observedAt != null && !observedAt.isBefore(windowStart) && samples.none { it.first == observedAt }) {
            samples += observedAt to limit.usedPercent
        }
        samples.sortBy { it.first }
        val first = samples.firstOrNull() ?: return null
        val last = samples.last()
        val hours = hoursBetween(first.first, last.first)
        if (hours < MIN_SPAN_HOURS) return null
        val perHour = (last.second - first.second) / hours
        val current = limit.usedPercent
        val atReset = current + perHour * hoursBetween(now, resetsAt)
        val exhaustion = if (atReset >= 100 && perHour > 0) {
            now.plusMillis(((100 - current) / perHour * 3_600_000).toLong())
        } else null
        return Projection(perHour * 24, atReset, exhaustion)
    }

    /** Lo que falta hasta [until]; nunca negativo. */
    fun remaining(until: Instant): Span {
        val minutes = maxOf(0L, Duration.between(now, until).toMinutes())
        return Span(minutes / 1_440, (minutes % 1_440) / 60, minutes % 60)
    }

    /** La antigüedad de [date]: segundos, minutos, horas o días; nunca negativa. */
    fun age(of: Instant): Age {
        val seconds = maxOf(0L, Duration.between(of, now).seconds)
        return when {
            seconds < 60 -> Age(seconds, Age.Unit.SECONDS)
            seconds < 3_600 -> Age(seconds / 60, Age.Unit.MINUTES)
            seconds < 86_400 -> Age(seconds / 3_600, Age.Unit.HOURS)
            else -> Age(seconds / 86_400, Age.Unit.DAYS)
        }
    }

    /** [instant] en la hora local, para «sáb 15:00». */
    fun local(instant: Instant): LocalDateTime = instant.atZone(zone).toLocalDateTime()

    private fun hoursBetween(from: Instant, to: Instant): Double = Duration.between(from, to).toMillis() / 3_600_000.0

    private companion object {
        const val OLD_SECONDS = 3_600L
        const val MIN_SPAN_HOURS = 0.5
    }
}
