package com.unixcision.uniconnect.android.domain

import java.time.Duration
import java.time.Instant

/**
 * Lo que dibuja la gráfica de 7 días de una cuenta (§4.1): una línea por límite, de 0 a 100 %, y
 * los resets que caen dentro.
 *
 * Los puntos salen del histórico y del uso actual, que es la muestra más nueva aunque el escritorio
 * no la haya guardado todavía. Es histórico: cada punto lleva su fecha.
 */
data class UsageChart(val start: Instant, val end: Instant, val series: List<Series>, val resets: List<Instant>) {
    /** Los puntos de un límite, de más viejo a más nuevo. */
    data class Series(val id: String, val name: LimitName, val points: List<Pair<Instant, Double>>)

    /** Si hay algo que dibujar. */
    val isEmpty: Boolean get() = series.none { it.points.isNotEmpty() }

    companion object {
        /** Los últimos 7 días hasta [now]. */
        val SPAN: Duration = Duration.ofDays(7)

        /**
         * La gráfica de [account] hasta [now]. Los límites van en el orden del uso actual y luego
         * los que solo están en el histórico, por orden alfabético.
         */
        fun of(account: UsageAccount, now: Instant): UsageChart {
            val start = now.minus(SPAN)
            val usage = account.usage
            val windows = usage?.limits.orEmpty().associate { it.id to it.windowMinutes }
            val ids = usage?.limits.orEmpty().map { it.id } +
                account.history.flatMap { it.limits.keys }.distinct().filter { id -> usage?.limits.orEmpty().none { it.id == id } }.sorted()
            val series = ids.map { id ->
                val points = account.history.mapNotNull { sample -> sample.limits[id]?.let { sample.at to it } }.toMutableList()
                val current = usage?.limits?.firstOrNull { it.id == id }
                val observedAt = usage?.observedAt
                if (current != null && observedAt != null && points.none { it.first == observedAt }) points += observedAt to current.usedPercent
                Series(id, LimitName.of(id, windows[id]), points.filter { !it.first.isBefore(start) && !it.first.isAfter(now) }.sortedBy { it.first })
            }
            // Un reset dentro de los 7 días: el comienzo de la ventana actual, o el propio reset si ya pasó.
            val resets = usage?.limits.orEmpty().flatMap { limit ->
                val resetsAt = limit.resetsAt ?: return@flatMap emptyList()
                val window = limit.windowMinutes?.takeIf { it > 0 }?.let { resetsAt.minus(Duration.ofMinutes(it.toLong())) }
                listOfNotNull(window, resetsAt)
            }.filter { !it.isBefore(start) && !it.isAfter(now) }.distinct().sorted()
            return UsageChart(start, now, series, resets)
        }
    }
}
