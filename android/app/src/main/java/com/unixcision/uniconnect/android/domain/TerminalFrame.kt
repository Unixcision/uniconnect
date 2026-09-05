package com.unixcision.uniconnect.android.domain

/** Applies row replacement deltas without reinterpreting the styles of untouched rows. */
data class TerminalFrame(val snapshot: TerminalSnapshot, val full: Boolean, val clearedRows: Set<Int>) {
    fun applyingTo(previous: TerminalSnapshot?): TerminalSnapshot {
        val incomingRevision = snapshot.revision
        val previousRevision = previous?.revision
        if (incomingRevision != null && previousRevision != null && incomingRevision <= previousRevision) return previous
        if (full) return snapshot
        if (previous == null || previous.columns != snapshot.columns || previous.rows != snapshot.rows) throw FullReplayRequired()
        val replacedRows = clearedRows + snapshot.spans.map { it.row }
        return snapshot.copy(
            spans = (previous.spans.filter { it.row !in replacedRows } + snapshot.spans).sortedWith(compareBy({ it.row }, { it.column })),
            foreground = snapshot.foreground ?: previous.foreground,
            background = snapshot.background ?: previous.background,
            cursor = snapshot.cursor ?: previous.cursor,
            scrollbackRows = previous.scrollbackRows,
            scrollbackSpans = previous.scrollbackSpans,
        )
    }

    class FullReplayRequired : Exception()
}
