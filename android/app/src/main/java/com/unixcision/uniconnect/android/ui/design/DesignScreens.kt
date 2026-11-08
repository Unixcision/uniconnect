package com.unixcision.uniconnect.android.ui.design

import androidx.compose.runtime.Composable
import com.unixcision.uniconnect.android.domain.DesignTheme
import com.unixcision.uniconnect.android.ui.HomeDestination
import com.unixcision.uniconnect.android.ui.design.arena.ArenaDrawer
import com.unixcision.uniconnect.android.ui.design.arena.ArenaHome
import com.unixcision.uniconnect.android.ui.design.arena.ArenaMachine
import com.unixcision.uniconnect.android.ui.design.lima.LimaDrawer
import com.unixcision.uniconnect.android.ui.design.lima.LimaHome
import com.unixcision.uniconnect.android.ui.design.lima.LimaMachine
import com.unixcision.uniconnect.android.ui.design.nieve.NieveDrawer
import com.unixcision.uniconnect.android.ui.design.nieve.NieveHome
import com.unixcision.uniconnect.android.ui.design.nieve.NieveMachine
import com.unixcision.uniconnect.android.ui.design.obsidiana.ObsidianaDrawer
import com.unixcision.uniconnect.android.ui.design.obsidiana.ObsidianaHome
import com.unixcision.uniconnect.android.ui.design.obsidiana.ObsidianaMachine
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/*
 * Each design is a structure of its own, not a palette: the same models and actions, drawn by
 * four different screens. These three entry points pick the one of the design in force.
 */

/** The home of the design in force, top bar included. */
@Composable
fun DesignedHome(model: HomeModel, actions: HomeActions) = when (UniTheme.tokens.theme) {
    DesignTheme.NIEVE -> NieveHome(model, actions)
    DesignTheme.OBSIDIANA -> ObsidianaHome(model, actions)
    DesignTheme.ARENA -> ArenaHome(model, actions)
    DesignTheme.LIMA -> LimaHome(model, actions)
}

/**
 * The machine screen of the design in force, header included. [menu] is the machine's overflow
 * button (edit, relaunch every AI, remove), drawn wherever the design puts its actions.
 */
@Composable
fun DesignedMachine(model: MachineModel, actions: MachineActions, menu: @Composable () -> Unit) = when (UniTheme.tokens.theme) {
    DesignTheme.NIEVE -> NieveMachine(model, actions, menu)
    DesignTheme.OBSIDIANA -> ObsidianaMachine(model, actions, menu)
    DesignTheme.ARENA -> ArenaMachine(model, actions, menu)
    DesignTheme.LIMA -> LimaMachine(model, actions, menu)
}

/** The side menu of the design in force; it draws its own `ModalDrawerSheet`. */
@Composable
fun DesignedDrawer(model: DrawerModel, onGo: (HomeDestination) -> Unit) = when (UniTheme.tokens.theme) {
    DesignTheme.NIEVE -> NieveDrawer(model, onGo)
    DesignTheme.OBSIDIANA -> ObsidianaDrawer(model, onGo)
    DesignTheme.ARENA -> ArenaDrawer(model, onGo)
    DesignTheme.LIMA -> LimaDrawer(model, onGo)
}
