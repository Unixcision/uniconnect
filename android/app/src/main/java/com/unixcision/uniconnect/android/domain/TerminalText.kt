package com.unixcision.uniconnect.android.domain

/**
 * El texto de una pantalla de terminal, para seleccionarlo y copiarlo.
 *
 * Existe porque la pantalla es una rejilla de trozos con estilo, no texto: para poder copiar hay
 * que recomponer cada fila en su columna. Incluye el historial que traiga la pantalla por encima,
 * quita los espacios de relleno del final de cada fila y las filas vacías del final, que en un
 * terminal casi siempre son hueco y no contenido.
 */
object TerminalText {
    fun of(snapshot: TerminalSnapshot): String {
        val lines = rows(snapshot.scrollbackSpans, snapshot.scrollbackRows) + rows(snapshot.spans, snapshot.rows)
        return lines.dropLastWhile { it.isEmpty() }.joinToString("\n")
    }

    private fun rows(spans: List<TerminalSnapshot.Span>, count: Int): List<String> {
        val byRow = spans.groupBy { it.row }
        return (0 until count).map { row ->
            val line = StringBuilder()
            var cell = 0
            for (span in byRow[row].orEmpty().sortedBy { it.column }) {
                if (span.style.invisible) continue
                if (span.column > cell) repeat(span.column - cell) { line.append(' ') }
                line.append(span.text)
                cell = span.column + span.cellWidth
            }
            line.toString().trimEnd()
        }
    }
}
