package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NoticeDeliveryCoordinatorTest {
    private val machine = Machine("machine-a", "Mi máquina", requireNotNull(MachineEndpoint.parse("100.64.0.1", "58465")))
    private fun notice(id: String = "notice-a", read: Boolean = false) = RemoteNotice(id, "workspace-a", "window-a", 10, read)

    @Test fun replayAndLiveDuplicateShareOneDeliveryIncludingAfterRestart() = runBlocking {
        val repository = MemoryRepository()
        val publisher = MemoryPublisher()
        NoticeDeliveryCoordinator(repository, publisher).deliver(machine, listOf(notice(), notice()))
        NoticeDeliveryCoordinator(repository, publisher).deliver(machine, listOf(notice()))
        assertEquals(listOf("machine-a/notice-a"), publisher.delivered)
    }

    @Test fun sameNoticeIdentifierOnAnotherMachineIsIndependent() = runBlocking {
        val repository = MemoryRepository()
        val publisher = MemoryPublisher()
        val coordinator = NoticeDeliveryCoordinator(repository, publisher)
        coordinator.deliver(machine, listOf(notice()))
        coordinator.deliver(machine.copy(id = "machine-b"), listOf(notice()))
        assertEquals(listOf("machine-a/notice-a", "machine-b/notice-a"), publisher.delivered)
    }

    @Test fun readNoticesAreRememberedWithoutAlerting() = runBlocking {
        val repository = MemoryRepository()
        val publisher = MemoryPublisher()
        val coordinator = NoticeDeliveryCoordinator(repository, publisher)
        coordinator.deliver(machine, listOf(notice(read = true)))
        coordinator.deliver(machine, listOf(notice(read = false)))
        assertTrue(publisher.delivered.isEmpty())
        assertEquals(setOf("notice-a"), repository.deliveredIDs(machine.id))
    }

    @Test fun failedPermissionDoesNotAcknowledgeOrLoseTheNotice() = runBlocking {
        val repository = MemoryRepository()
        val publisher = MemoryPublisher().apply { enabled = false }
        val coordinator = NoticeDeliveryCoordinator(repository, publisher)
        val failure = runCatching { coordinator.deliver(machine, listOf(notice())) }.exceptionOrNull()
        assertTrue(failure is NoticeDeliveryCoordinator.DeliveryDisabled)
        assertTrue(repository.deliveredIDs(machine.id).isEmpty())
        publisher.enabled = true
        coordinator.deliver(machine, listOf(notice()))
        assertEquals(listOf("machine-a/notice-a"), publisher.delivered)
    }

    private class MemoryRepository : NoticeDeliveryRepository {
        private val values = mutableMapOf<String, MutableSet<String>>()
        override suspend fun deliveredIDs(machineID: String): Set<String> = values[machineID]?.toSet().orEmpty()
        override suspend fun remember(machineID: String, noticeID: String) { values.getOrPut(machineID) { mutableSetOf() }.add(noticeID) }
    }

    private class MemoryPublisher : NoticePublisher {
        var enabled = true
        val delivered = mutableListOf<String>()
        override suspend fun publish(machine: Machine, notice: RemoteNotice): Boolean {
            if (!enabled) return false
            delivered += "${machine.id}/${notice.id}"
            return true
        }
    }
}
