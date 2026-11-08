package com.unixcision.uniconnect.android.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CleaningServices
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.Hub
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.ui.graphics.vector.ImageVector
import com.unixcision.uniconnect.android.R

/**
 * One page of Ajustes, opened from the side menu: each shows only its own sections, so nothing
 * has to be found by scrolling one long sheet.
 */
enum class SettingsPage(val title: Int, val note: Int, val icon: ImageVector) {
    APPEARANCE(R.string.settings_page_appearance, R.string.settings_page_appearance_note, Icons.Rounded.Palette),
    TERMINAL(R.string.settings_page_terminal, R.string.settings_page_terminal_note, Icons.Rounded.Terminal),
    VOICE(R.string.settings_page_voice, R.string.settings_page_voice_note, Icons.Rounded.Mic),
    FILES(R.string.settings_page_files, R.string.settings_page_files_note, Icons.Rounded.CloudUpload),
    CONNECTIONS(R.string.settings_page_connections, R.string.settings_page_connections_note, Icons.Rounded.Hub),
    CLEANUP(R.string.settings_page_cleanup, R.string.settings_page_cleanup_note, Icons.Rounded.CleaningServices),
}
