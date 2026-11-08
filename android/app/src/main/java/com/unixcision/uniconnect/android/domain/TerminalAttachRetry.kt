package com.unixcision.uniconnect.android.domain

/**
 * Cuándo se repite un enganche automático a tmux que falló, antes de caer al espejo.
 *
 * Al abrir una ventana el móvil intentaba engancharse una sola vez: si ese intento caía por algo
 * pasajero (la sesión de una ventana recién abierta tardando un instante, un parpadeo de la red),
 * se quedaba en la copia de la ventana con un error y había que pulsar «tmux» a mano para algo
 * que habría funcionado un segundo después. Ahora un fallo pasajero se repite un par de veces;
 * uno que no va a cambiar (el equipo no tiene la orden, la ventana no es durable, falta aprobar
 * el dispositivo) se dice a la primera.
 */
object TerminalAttachRetry {
    /** Intentos en total, contando el primero. */
    const val MAX_ATTEMPTS = 3

    private val permanentCodes = setOf(
        "method_not_found", "unknown_method", "not_supported", "unsupported", "not_durable", "approval_required",
    )

    /** Códigos con los que el equipo dice que no tiene la orden: solo esos vetan la máquina. */
    val missingMethodCodes: Set<String> = setOf("method_not_found", "unknown_method")

    /**
     * Espera en milisegundos antes del intento siguiente tras [failure] en el intento [attempt]
     * (el primero es 1), o null si no se repite.
     */
    fun nextDelayMillis(attempt: Int, failure: Throwable): Long? {
        if (attempt >= MAX_ATTEMPTS) return null
        val passing = when (failure) {
            is MachineFailure.Transport, is MachineFailure.DeadlineExceeded, is MachineFailure.TerminalNotReady -> true
            is MachineFailure.Rejected -> failure.code !in permanentCodes
            is java.io.IOException -> true
            else -> false
        }
        return if (passing) 800L * attempt else null
    }
}
