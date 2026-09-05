"""Behavioral failures for staged terminal publication and persistent rollback."""

import copy
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import uuid

from uniconnect.runtime_transaction import RuntimeTransactionCoordinator, RuntimeTransactionError
from uniconnect.state import StateStore
from uniconnect.vault import Vault


class EventLoop:
    def __init__(self):
        self.callbacks = {}
        self.idles = []
        self.serial = 0

    def schedule(self, seconds, callback):
        self.serial += 1
        self.callbacks[self.serial] = callback
        return self.serial

    def cancel(self, handle):
        self.callbacks.pop(handle, None)

    def defer(self, callback):
        self.idles.append(callback)

    def drain(self):
        callbacks, self.idles = self.idles, []
        for callback in callbacks:
            callback()

    def deadline(self):
        callbacks, self.callbacks = list(self.callbacks.values()), {}
        for callback in callbacks:
            callback()


class Candidate:
    def __init__(self, number=1):
        self.generation = 0
        self.pid = 1000 + number
        self.readiness_token = uuid.uuid4().hex
        self.record = {"tmux": "fixture-" + str(number)}
        self.subscribers = []
        self.alive, self.started, self.stopped = False, False, False

    def subscribe_lifecycle(self, callback):
        self.subscribers.append(callback)
        return lambda: self.subscribers.remove(callback) if callback in self.subscribers else None

    def start_candidate(self):
        self.started = True
        self.generation += 1
        return self.generation

    def stop_candidate(self):
        self.stopped, self.alive = True, False
        self.generation += 1

    def is_candidate_alive(self, generation, pid):
        return self.alive and self.generation == generation and self.pid == pid

    def event(self, kind, **fields):
        event = dict(kind=kind, generation=self.generation, pid=self.pid)
        event.update(fields)
        for callback in list(self.subscribers):
            callback(event)

    def spawn(self):
        self.alive = True
        self.event("spawned")

    def ready(self, **overrides):
        proof = dict(kind="tmux-client-attached", token=self.readiness_token,
                     tmux=self.record["tmux"], clientPid=456)
        proof.update(overrides)
        self.event("ready", proof=proof)


class RuntimeTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory(prefix="uniconnect-runtime-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.vault = Vault(self.root)
        self.vault.initialize("runtime fixture password")
        self.store = StateStore(self.root, self.vault)
        self.workspace = {"id": str(uuid.uuid4()), "name": "Original", "kind": "ssh",
                          "credentialId": self.vault.put("ssh fixture@original.example.test"),
                          "windows": [{"id": str(uuid.uuid4()), "name": "Original window", "tmux": "fixture-1"}]}
        self.store.workspaces.append(self.workspace)
        self.store.save()
        self.window = self.workspace["windows"][0]
        self.before_state, self.before_vault = self.store.path.read_bytes(), self.vault.path.read_bytes()
        self.before_model = copy.deepcopy(self.store.data)
        self.loop = EventLoop()
        self.coordinator = RuntimeTransactionCoordinator(self.store, schedule=self.loop.schedule,
                                                        cancel_timer=self.loop.cancel, defer=self.loop.defer)
        self.results = []
        self.original_alive, self.published = True, False
        self.rollback_calls = 0

    def mutation(self):
        revision = self.vault.put("ssh fixture@candidate.example.test")
        self.workspace["credentialId"] = revision
        self.window["name"] = "Candidate window"
        return revision

    def publish(self, candidates, revision):
        self.assertTrue(self.original_alive)
        self.published = True

    def restore(self):
        self.rollback_calls += 1
        self.published = False

    def retire(self):
        self.assertTrue(self.published)
        self.assertFalse(self.store.journal_path.exists())
        self.original_alive = False

    def start(self, candidates, **overrides):
        callbacks = dict(mutate=self.mutation, publish=self.publish, restore_runtime=self.restore,
                         retire_originals=self.retire, on_complete=self.results.append)
        callbacks.update(overrides)
        self.coordinator.start(candidates, **callbacks)

    def assert_original_preserved(self):
        self.assertTrue(self.original_alive)
        self.assertEqual(self.store.path.read_bytes(), self.before_state)
        self.assertEqual(self.vault.path.read_bytes(), self.before_vault)
        self.assertEqual(self.store.data, self.before_model)
        self.assertIs(self.store.workspaces[0], self.workspace)
        self.assertIs(self.workspace["windows"][0], self.window)

    def test_spawn_or_uncorrelated_proof_never_marks_ready(self):
        candidate = Candidate()
        self.start([candidate])
        candidate.spawn()
        self.loop.drain()
        self.assertEqual(self.results, [])
        for proof in ({"kind": "process-started"}, {"token": "incorrect-token"}, {"tmux": "other-session"}, {"clientPid": 0}):
            candidate.ready(**proof)
            self.loop.drain()
            self.assertEqual(self.results, [])
        self.loop.deadline()
        self.assertEqual(self.results[0].code, "readiness-timeout")
        self.assertTrue(candidate.stopped)
        self.assert_original_preserved()

    def test_all_candidates_need_attachment_evidence_before_old_clients_retire(self):
        candidates = [Candidate(1), Candidate(2)]
        self.start(candidates)
        for candidate in candidates:
            candidate.spawn()
        candidates[0].ready()
        self.loop.drain()
        self.assertTrue(self.original_alive)
        self.assertEqual(self.results, [])
        candidates[1].ready()
        self.assertTrue(self.original_alive)
        self.loop.drain()
        self.assertEqual(len(self.results), 1)
        self.assertTrue(self.results[0].success)
        self.assertFalse(self.original_alive)
        self.assertTrue(all(not candidate.stopped for candidate in candidates))
        self.assertEqual(self.window["name"], "Candidate window")

    def test_exit_between_readiness_and_idle_commit_cancels_every_candidate(self):
        candidates = [Candidate(1), Candidate(2)]
        self.start(candidates)
        for candidate in candidates:
            candidate.spawn()
            candidate.ready()
        candidates[1].alive = False
        candidates[1].event("exited")
        self.loop.drain()
        self.assertEqual(len(self.results), 1)
        self.assertEqual(self.results[0].code, "candidate-exited")
        self.assertTrue(all(candidate.stopped for candidate in candidates))
        self.assert_original_preserved()

    def test_partial_publish_failure_rolls_back_vault_state_and_runtime(self):
        candidate = Candidate()

        def failed_publish(candidates, revision):
            self.published = True
            raise OSError("fixture UI insertion failed")

        self.start([candidate], publish=failed_publish)
        candidate.spawn()
        candidate.ready()
        self.loop.drain()
        self.assertFalse(self.results[0].success)
        self.assertEqual(self.rollback_calls, 1)
        self.assertFalse(self.published)
        self.assertTrue(candidate.stopped)
        self.assert_original_preserved()

    def test_persistence_failure_after_publish_restores_original_clients_and_exact_bytes(self):
        candidate = Candidate()
        self.store._failpoint = lambda stage: (_ for _ in ()).throw(OSError("fixture fsync failure")) if stage == "commit:before" else None
        self.start([candidate])
        candidate.spawn()
        candidate.ready()
        self.loop.drain()
        self.assertFalse(self.results[0].success)
        self.assertEqual(self.rollback_calls, 1)
        self.assertTrue(candidate.stopped)
        self.assert_original_preserved()

    def test_cancellation_during_staging_and_during_publication(self):
        candidate = Candidate()
        self.start([candidate])
        candidate.spawn()
        self.coordinator.cancel()
        candidate.ready()
        self.loop.drain()
        self.assertEqual(self.results[0].code, "cancelled")
        self.assert_original_preserved()
        self.results.clear()
        next_candidate = Candidate(2)

        def cancelled_publish(candidates, revision):
            self.published = True
            self.coordinator.cancel()

        self.start([next_candidate], publish=cancelled_publish)
        next_candidate.spawn()
        next_candidate.ready()
        self.loop.drain()
        self.assertEqual(self.results[0].code, "cancelled")
        self.assertEqual(self.rollback_calls, 1)
        self.assert_original_preserved()

    def test_stale_callback_cannot_commit_a_later_operation(self):
        old = Candidate()
        self.start([old])
        callback = old.subscribers[0]
        generation = old.generation
        self.coordinator.cancel()
        candidate = Candidate(2)
        self.start([candidate])
        callback({"kind": "ready", "generation": generation, "pid": old.pid,
                  "proof": {"kind": "tmux-client-attached", "token": old.readiness_token,
                            "tmux": old.record["tmux"], "clientPid": 456}})
        self.loop.drain()
        self.assertTrue(self.coordinator.active)
        self.assertEqual(len(self.results), 1)
        self.coordinator.cancel()

    def test_changed_workspace_during_staging_does_not_overwrite_new_work(self):
        candidate = Candidate()
        self.start([candidate])
        self.store.mutate(lambda data: data["settings"].update(locale="es"))
        changed_state = self.store.path.read_bytes()
        candidate.spawn()
        candidate.ready()
        self.loop.drain()
        self.assertEqual(self.results[0].code, "runtime-state-changed")
        self.assertEqual(self.store.path.read_bytes(), changed_state)
        self.assertTrue(self.original_alive)

    def test_only_one_runtime_operation_may_claim_a_store(self):
        candidate = Candidate()
        self.start([candidate])
        other = RuntimeTransactionCoordinator(self.store, schedule=self.loop.schedule,
                                              cancel_timer=self.loop.cancel, defer=self.loop.defer)
        with self.assertRaises(RuntimeTransactionError):
            other.start([], mutate=lambda: None, publish=lambda *_: None, restore_runtime=lambda: None,
                        retire_originals=lambda: None, on_complete=lambda _: None)
        self.coordinator.cancel()

    def test_synchronous_start_failure_disposes_unstarted_candidates_too(self):
        candidates = [Candidate(1), Candidate(2)]

        def fail_start():
            raise OSError("fixture launch failure")

        candidates[0].start_candidate = fail_start
        self.start(candidates)
        self.assertEqual(self.results[0].code, "candidate-start-failed")
        self.assertTrue(all(candidate.stopped for candidate in candidates))
        self.assertFalse(candidates[1].started)
        self.assert_original_preserved()

    def test_liveness_adapter_failure_fails_closed_without_escaping_callback(self):
        candidate = Candidate()
        self.start([candidate])
        candidate.spawn()

        def failed_liveness(*_):
            raise OSError("fixture process inspection failed")

        candidate.is_candidate_alive = failed_liveness
        candidate.ready()
        self.assertEqual(self.results[0].code, "candidate-exited")
        self.assertTrue(candidate.stopped)
        self.assert_original_preserved()


if __name__ == "__main__":
    unittest.main()
