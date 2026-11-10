package com.unixcision.uniconnect.android.domain

/**
 * La cuenta de una IA tal y como la leyó la sonda en esta llamada (`account` sin `state`).
 *
 * Todo puede faltar: [email] solo con `oauth` o `chatgpt`; [method] es `oauth`, `chatgpt`,
 * `api_key`, `bedrock`, `vertex` o `foundry`; [config] dice qué fichero se leyó, que es lo que
 * explica por qué varias ventanas comparten cuenta.
 */
data class AccountInfo(
    val email: String? = null,
    val method: String? = null,
    val plan: String? = null,
    val organization: String? = null,
    val osUser: String? = null,
    val config: String? = null,
    val readAt: String? = null,
)
