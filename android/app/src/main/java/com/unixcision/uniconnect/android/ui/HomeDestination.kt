package com.unixcision.uniconnect.android.ui

import com.unixcision.uniconnect.android.domain.RelaunchVerb

/** Where an entry of the side menu leads; every design's menu offers the same destinations. */
sealed interface HomeDestination {
    data object Machines : HomeDestination
    data object Files : HomeDestination
    data object History : HomeDestination
    data object Notices : HomeDestination
    data class Settings(val page: SettingsPage) : HomeDestination
    data object Diagnostics : HomeDestination

    /** «Cuentas de IA» a pantalla completa (`accounts.v1`). */
    data object Accounts : HomeDestination

    /** «Relanzar» o «Actualizar Claude» en todos los equipos conectados que lo anuncian, en un solo diálogo. */
    data class Everywhere(val verb: RelaunchVerb) : HomeDestination
}
