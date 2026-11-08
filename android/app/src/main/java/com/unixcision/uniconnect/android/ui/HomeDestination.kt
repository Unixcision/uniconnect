package com.unixcision.uniconnect.android.ui

/** Where an entry of the side menu leads; every design's menu offers the same destinations. */
sealed interface HomeDestination {
    data object Machines : HomeDestination
    data object Files : HomeDestination
    data object History : HomeDestination
    data object Notices : HomeDestination
    data class Settings(val page: SettingsPage) : HomeDestination
    data object Diagnostics : HomeDestination
}
