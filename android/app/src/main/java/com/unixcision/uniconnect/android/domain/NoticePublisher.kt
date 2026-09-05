package com.unixcision.uniconnect.android.domain

/** Publishes a privacy-preserving alert; false means delivery is currently disabled. */
interface NoticePublisher {
    suspend fun publish(machine: Machine, notice: RemoteNotice): Boolean
}
