package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.Flow

interface NotificationClient {
    fun observe(machine: Machine): Flow<List<RemoteNotice>>
}
