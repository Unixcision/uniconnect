package com.unixcision.uniconnect.android.domain

/**
 * Una ventana de la respuesta de `mobile.accounts.list`, en el orden de la barra lateral.
 *
 * [stateWire] llega crudo; [state] es su lectura. [account] solo viene si hay IA y su host se leyó
 * en esta llamada: nunca es una cuenta recordada.
 */
data class AccountWindow(
    val workspaceID: String,
    val workspace: String,
    val terminalID: String,
    val window: String,
    val hostKey: String,
    val tmuxSession: String?,
    val stateWire: String,
    val agent: AccountAgent?,
    val account: AccountInfo?,
) {
    val state: AccountWindowState? get() = AccountWindowState.named(stateWire)
}
