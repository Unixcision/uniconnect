package com.unixcision.uniconnect.android.domain

interface NoticeDeliveryRepository {
    suspend fun deliveredIDs(machineID: String): Set<String>
    suspend fun remember(machineID: String, noticeID: String)
}
