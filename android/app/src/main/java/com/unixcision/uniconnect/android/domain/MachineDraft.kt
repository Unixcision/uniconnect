package com.unixcision.uniconnect.android.domain

/**
 * A machine as typed into the form, before it is anything the app can connect to.
 *
 * Validation lives here rather than in the screen so that adding and editing answer exactly the
 * same questions, and so the machine being edited is never mistaken for a duplicate of itself.
 */
data class MachineDraft(val name: String, val address: String, val port: String) {
    /** The endpoint this draft describes, or `null` when the address or the port do not parse. */
    val endpoint: MachineEndpoint? get() = MachineEndpoint.parse(address, port)

    /**
     * What stops this draft from being saved, or `null` when nothing does.
     *
     * - Parameter existing: the machines already stored.
     * - Parameter editing: the id of the machine being edited, which is excluded from the
     *   duplicate check because keeping its own address is not a conflict.
     */
    fun problem(existing: List<Machine>, editing: String? = null): Problem? = when {
        name.trim().length !in 1..80 || name.any { it.isISOControl() } -> Problem.NAME
        port.trim().toIntOrNull() !in 1..65535 -> Problem.PORT
        endpoint == null -> Problem.ADDRESS
        existing.any { it.endpoint == endpoint && it.id != editing } -> Problem.DUPLICATE
        else -> null
    }

    /** The machine this draft becomes. Only call it once [problem] has answered `null`. */
    fun machine(id: String) = Machine(id, name.trim(), requireNotNull(endpoint))

    /** Why a draft cannot be saved. */
    enum class Problem {
        /** Empty, too long, or carrying control characters. */
        NAME,
        /** Not a number between 1 and 65535. */
        PORT,
        /** Not an address this app will talk to over the tailnet. */
        ADDRESS,
        /** Another stored machine already answers at this address and port. */
        DUPLICATE,
    }
}
