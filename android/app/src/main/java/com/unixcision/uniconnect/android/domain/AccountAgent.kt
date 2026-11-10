package com.unixcision.uniconnect.android.domain

/** La IA de una ventana, como la nombra el equipo: `claude`, «Claude Code» y si corre como root. */
data class AccountAgent(val provider: String, val displayName: String, val asRoot: Boolean?)
