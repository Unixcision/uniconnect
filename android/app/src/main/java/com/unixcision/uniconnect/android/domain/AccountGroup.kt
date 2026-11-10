package com.unixcision.uniconnect.android.domain

/**
 * Un grupo de filas: un espacio de trabajo («Por espacio») o una cuenta («Por cuenta»).
 *
 * [hostCount] cuenta los hosts distintos donde están sus ventanas, contando el equipo: el mismo
 * `local` de dos equipos son dos hosts.
 */
data class AccountGroup(val key: Key, val rows: List<AccountRow>) {
    val hostCount: Int get() = rows.map { it.machineID to it.window.hostKey }.distinct().size

    /** Qué junta un grupo. */
    sealed interface Key {
        /** Un espacio de trabajo de un equipo. */
        data class Workspace(val machineID: String, val workspaceID: String, val name: String, val machineName: String) : Key

        /** Una cuenta con email. */
        data class Email(val email: String, val colorIndex: Int) : Key

        /** Las sesiones de un método sin email (clave de API, Bedrock…). */
        data class Method(val method: AccountMethod) : Key

        /** Las IA sin sesión. */
        data object NoSession : Key

        /** Las que no se pudieron leer. */
        data object Unread : Key

        /** Las ventanas sin IA, cuando se enseñan. */
        data object WithoutAgent : Key

        /** Sesiones `ok` sin email ni método conocido. */
        data object NoEmail : Key
    }
}
