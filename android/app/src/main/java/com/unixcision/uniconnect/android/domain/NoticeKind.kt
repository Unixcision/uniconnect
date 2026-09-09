package com.unixcision.uniconnect.android.domain

/**
 * Why a host raised a notice, as the host says it (`kind` in the mobile notification payload).
 *
 * ``ATTENTION`` means an agent waits for the reader (permission, question); ``FINISHED`` means a
 * turn ended; ``INFO`` is anything else or a host that does not say. The phone never reads the
 * body, so this is the only thing it can tell the reader about the notice.
 */
enum class NoticeKind {
    ATTENTION, FINISHED, INFO;

    companion object {
        fun parse(raw: String?): NoticeKind = when (raw) { "attention" -> ATTENTION; "finished" -> FINISHED; else -> INFO }
    }
}
