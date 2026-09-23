package com.unixcision.uniconnect.android.domain

/**
 * Un equipo guardado visto desde el medidor de Adjuntos: si ahora mismo se puede hablar con él y
 * si su UniConnect sabe de la bandeja (`inbox.v1`). Los que no, se nombran igual con el motivo:
 * que un equipo desaparezca de la lista no explica nada.
 */
data class InboxCandidate(val machine: Machine, val connected: Boolean, val keepsInbox: Boolean) {
    val available: Boolean get() = connected && keepsInbox
}
