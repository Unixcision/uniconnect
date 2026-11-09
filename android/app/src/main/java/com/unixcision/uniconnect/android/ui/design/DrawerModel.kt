package com.unixcision.uniconnect.android.ui.design

import androidx.compose.runtime.Immutable
import com.unixcision.uniconnect.android.domain.DesignTheme
import com.unixcision.uniconnect.android.domain.HomeSummary

/** What the side menu shows besides its entries: how the machines are and what the app is. */
@Immutable
data class DrawerModel(
    val summary: HomeSummary,
    val version: String,
    /** The connection report has something to tell: its entry gets a mark. */
    val troubled: Boolean,
    /** The design in force, for an entry that names it ("Apariencia · Obsidiana"). */
    val theme: DesignTheme,
    /** Some connected machine relaunches its AIs: «Relanzar las IA de todos los equipos» is offered. */
    val relaunchesEverywhere: Boolean = false,
    /** Some connected machine updates Claude: «Actualizar Claude en todos los equipos» is offered. */
    val updatesEverywhere: Boolean = false,
)
