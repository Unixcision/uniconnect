package com.unixcision.uniconnect.android.domain

/**
 * Lo que una fila enseña en el sitio de la cuenta: el email con su color, el método cuando no es
 * una cuenta con email, o el estado en gris.
 */
sealed interface AccountLabel {
    /** Una cuenta con email; [colorIndex] es su color en [AccountPalette.COLORS]. */
    data class Email(val email: String, val colorIndex: Int) : AccountLabel

    /** Una sesión sin email por su método: clave de API, Bedrock, Vertex o Foundry. */
    data class Method(val method: AccountMethod) : AccountLabel

    /** No hay cuenta que enseñar, y por qué. [osUser] es el usuario dueño de la IA, si se sabe. */
    data class Status(val status: AccountStatus, val osUser: String? = null) : AccountLabel

    /** Un estado que esta versión no conoce, tal cual llegó. */
    data class Unknown(val wire: String) : AccountLabel
}

/** Los métodos que se enseñan en lugar del email (`method` distinto de `oauth` y `chatgpt`). */
enum class AccountMethod(val wire: String) {
    API_KEY("api_key"), BEDROCK("bedrock"), VERTEX("vertex"), FOUNDRY("foundry");

    companion object {
        fun named(raw: String?): AccountMethod? = entries.firstOrNull { it.wire == raw }
    }
}

/** Por qué una fila no tiene cuenta que enseñar. */
enum class AccountStatus {
    NO_SESSION, NOT_READABLE, NOT_EXPOSED, HOST_UNREACHABLE, NO_AGENT, SESSION_NOT_ALIVE, NO_TMUX, DEAD_PANE, AMBIGUOUS_IDENTITY,

    /** La sonda dice `ok` pero no da ni email ni un método conocido. */
    NO_EMAIL,
}
