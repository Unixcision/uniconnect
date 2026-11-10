package com.unixcision.uniconnect.android.domain

/**
 * Lo que un equipo contesta a `mobile.accounts.list` (`accounts.v1`): sus hosts y sus ventanas,
 * leídos en vivo en esa llamada.
 *
 * [checkedAt] es cuándo terminó la respuesta (ISO 8601 UTC); de ahí sale «Leído en vivo hace N s».
 */
data class AccountsReport(
    val version: Int,
    val checkedAt: String?,
    val hosts: List<AccountHost>,
    val windows: List<AccountWindow>,
)
