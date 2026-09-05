package com.unixcision.uniconnect.android.domain

/** Reconciles retained snapshots and live notices through the same durable delivery path. */
class NoticeDeliveryCoordinator(
    private val repository: NoticeDeliveryRepository,
    private val publisher: NoticePublisher,
) {
    suspend fun deliver(machine: Machine, notices: List<RemoteNotice>) {
        val delivered = repository.deliveredIDs(machine.id).toMutableSet()
        for (notice in notices.sortedWith(compareBy({ it.createdAt }, { it.id }))) {
            if (notice.id in delivered) continue
            if (!notice.isRead && !publisher.publish(machine, notice)) throw DeliveryDisabled()
            // Commit only after a successful publish. Stable OS notification IDs cover an interrupted commit.
            repository.remember(machine.id, notice.id)
            delivered += notice.id
        }
    }

    class DeliveryDisabled : Exception()
}
