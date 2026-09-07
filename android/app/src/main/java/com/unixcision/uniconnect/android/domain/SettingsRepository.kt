package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.Flow

/** Durable storage for the app's own preferences. Nothing here reaches a remote machine. */
interface SettingsRepository {
    val settings: Flow<AppSettings>
    suspend fun update(settings: AppSettings)
}
