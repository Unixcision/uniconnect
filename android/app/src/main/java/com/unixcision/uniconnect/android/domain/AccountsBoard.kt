package com.unixcision.uniconnect.android.domain

import java.time.Instant

/**
 * «Cuentas de IA» de todos los equipos de una misma pasada, para filtrarlas y agruparlas.
 *
 * Solo junta lo que llegó en esta pasada: un equipo que falla aporta un aviso y ninguna fila.
 */
data class AccountsBoard(val machines: List<MachineAccounts>) {
    /** Todas las ventanas leídas, equipo por equipo y en el orden de su barra lateral. */
    val rows: List<AccountRow> = machines.flatMap { machine ->
        val report = machine.report ?: return@flatMap emptyList()
        val hosts = report.hosts.associateBy { it.hostKey }
        report.windows.map { AccountRow(machine.machineID, machine.machineName, it, hosts[it.hostKey]) }
    }

    /** Lo que no se pudo leer: primero los equipos enteros, luego cada host que no sea `ok`. */
    val notices: List<AccountNotice> get() = machines.mapNotNull { machine ->
        machine.failure?.takeIf { machine.report == null }?.let { AccountNotice.MachineFailed(machine.machineName, it) }
    } + machines.flatMap { machine ->
        machine.report?.hosts.orEmpty().filter { !it.readable }.map { host ->
            AccountNotice.HostUnreadable(listOf(machine.machineName, host.label.ifBlank { host.hostKey }).filter { it.isNotBlank() }.joinToString(" · "), host.state)
        }
    }

    /**
     * El momento de la lectura más vieja de esta pasada, en milisegundos: con varios equipos, «hace
     * N s» cuenta desde el que contestó antes. Nulo si ninguno contestó o no dio la hora.
     */
    val checkedAtMillis: Long? get() = machines.mapNotNull { it.report?.checkedAt?.let(::epochMillis) }.minOrNull()

    /** Los segundos desde [checkedAtMillis], nunca negativos aunque los relojes no coincidan. */
    fun ageSeconds(nowMillis: Long): Long? = checkedAtMillis?.let { maxOf(0L, (nowMillis - it) / 1000) }

    /** Las filas que se ven con el interruptor «Ventanas sin IA» en [showWithoutAgent]. */
    fun visible(showWithoutAgent: Boolean): List<AccountRow> = if (showWithoutAgent) rows else rows.filter { !it.withoutAgent }

    /**
     * Las fichas: «Todas», una por email de más a menos ventanas, «Sin sesión» y «Sin leer».
     *
     * Se cuentan sobre lo visible con el interruptor, no con el buscador: las fichas no bailan al
     * escribir. Si la ficha elegida ya no tiene ventanas, sigue con un cero, para poder quitarla.
     */
    fun chips(query: AccountsQuery): List<AccountChipCount> {
        val visible = visible(query.showWithoutAgent)
        val emails = visible.mapNotNull { it.email }.groupingBy { it }.eachCount().entries
            .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .map { AccountChipCount(AccountChip.Email(it.key), it.value, AccountPalette.indexOf(it.key)) }
        val chosen = query.chip as? AccountChip.Email
        val kept = if (chosen != null && emails.none { it.chip == chosen }) {
            listOf(AccountChipCount(chosen, 0, AccountPalette.indexOf(chosen.email)))
        } else emptyList()
        return listOf(AccountChipCount(AccountChip.All, visible.size)) + emails + kept + listOf(
            AccountChipCount(AccountChip.NoSession, visible.count { it.matches(AccountChip.NoSession) }),
            AccountChipCount(AccountChip.Unread, visible.count { it.unread }),
        )
    }

    /** Las filas que quedan con [query]: interruptor, ficha y buscador. */
    fun filtered(query: AccountsQuery): List<AccountRow> =
        visible(query.showWithoutAgent).filter { it.matches(query.chip) && it.matches(query.search) }

    /** Los grupos que se pintan con [query]. Ningún grupo vacío. */
    fun groups(query: AccountsQuery): List<AccountGroup> {
        val rows = filtered(query)
        return when (query.grouping) {
            AccountsQuery.Grouping.BY_WORKSPACE -> rows
                .groupBy { AccountGroup.Key.Workspace(it.machineID, it.window.workspaceID, it.window.workspace, it.machineName) }
                .map { (key, rows) -> AccountGroup(key, rows) }
            AccountsQuery.Grouping.BY_ACCOUNT -> rows.groupBy(::accountKey).map { (key, rows) -> AccountGroup(key, rows) }
                .sortedWith(compareBy<AccountGroup> { rank(it.key) }.thenByDescending { it.rows.size }.thenBy { (it.key as? AccountGroup.Key.Email)?.email.orEmpty() })
        }
    }

    private fun accountKey(row: AccountRow): AccountGroup.Key = when (val label = row.label) {
        is AccountLabel.Email -> AccountGroup.Key.Email(label.email, label.colorIndex)
        is AccountLabel.Method -> AccountGroup.Key.Method(label.method)
        is AccountLabel.Unknown -> AccountGroup.Key.Unread
        is AccountLabel.Status -> when {
            row.withoutAgent -> AccountGroup.Key.WithoutAgent
            label.status == AccountStatus.NO_SESSION -> AccountGroup.Key.NoSession
            label.status == AccountStatus.NO_EMAIL -> AccountGroup.Key.NoEmail
            else -> AccountGroup.Key.Unread
        }
    }

    /** Primero las cuentas, luego los métodos sin email y al final lo que no tiene cuenta. */
    private fun rank(key: AccountGroup.Key): Int = when (key) {
        is AccountGroup.Key.Email -> 0
        is AccountGroup.Key.Method -> 1 + key.method.ordinal
        AccountGroup.Key.NoEmail -> 10
        AccountGroup.Key.NoSession -> 11
        AccountGroup.Key.Unread -> 12
        AccountGroup.Key.WithoutAgent -> 13
        is AccountGroup.Key.Workspace -> 14
    }

    private fun epochMillis(iso: String): Long? = runCatching { Instant.parse(iso).toEpochMilli() }.getOrNull()
}
