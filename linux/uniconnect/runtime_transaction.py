"""Coordinate candidate terminal readiness with the durable workspace transaction.

This service has no GTK dependency. Its lifecycle adapter must derive ``ready``
from the candidate VTE child's correlated tmux attachment, never from successful
process spawning. GUI callbacks run on the same event-loop thread as ``start``.
Original terminals remain alive until candidate publication and durable commit
have both succeeded.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass
import hashlib
import json
import threading
from typing import Any


@dataclass(frozen=True)
class RuntimeTransactionResult:
    """A stable result suitable for UI translation without leaking connection data."""

    success: bool
    code: str
    value: Any = None
    cleanup_errors: tuple[str, ...] = ()


class RuntimeTransactionError(RuntimeError):
    """A failed runtime prerequisite, expressed as a stable non-secret code."""


class RuntimeTransactionCoordinator:
    """Stage asynchronous terminal candidates, then publish them transactionally.

    ``schedule(seconds, callback)``, ``cancel_timer(handle)`` and ``defer(callback)``
    come from the GUI event loop (or an injected deterministic test scheduler).

    Each candidate supplies ``subscribe_lifecycle(callback) -> unsubscribe``,
    ``start_candidate() -> generation``, ``stop_candidate()``,
    ``is_candidate_alive(generation, pid)``, ``generation``, ``pid``,
    ``readiness_token`` and ``record``. Lifecycle events are dictionaries containing
    ``kind``, ``generation`` and ``pid``. A ready event additionally includes
    ``proof={kind: 'tmux-client-attached', token, tmux, clientPid}`` from an actual
    child-correlated tmux client verification.

    Candidates use detached model copies and attach-only launch policy. ``publish``
    rebinds them to live records and swaps widgets without stopping originals;
    ``restore_runtime`` reverses any partial swap. Only ``retire_originals`` may
    stop the old clients, and runs after the authenticated persistent commit.
    """

    def __init__(self, store, *, schedule, cancel_timer, defer):
        self.store = store
        self._schedule, self._cancel_timer, self._defer = schedule, cancel_timer, defer
        self.state = "idle"
        self.result = None
        self._serial = 0
        self._timer = None
        self._progress = {}
        self._commit_queued = False
        self._cancel_requested = False
        self._failure_code = None
        self._starting = False
        self._thread_id = None

    @property
    def active(self) -> bool:
        return self.state in ("staging", "committing")

    @staticmethod
    def _state_fingerprint(data) -> str:
        snapshot = copy.deepcopy(data)
        # A periodic checkpoint alone does not invalidate a prepared runtime plan.
        snapshot.pop("savedAt", None)
        return hashlib.sha256(json.dumps(snapshot, sort_keys=True, ensure_ascii=False).encode()).hexdigest()

    def _assert_thread(self):
        if self._thread_id != threading.get_ident():
            raise RuntimeTransactionError("runtime-callback-wrong-thread")

    def start(self, candidates, *, mutate, publish, restore_runtime, retire_originals,
              on_complete, timeout=20.0, reason="runtime-import"):
        """Start one operation after read-only preflight; return this cancellable handle.

        Callback contracts are ``mutate() -> value``, ``publish(candidates, value)``,
        ``restore_runtime()``, ``retire_originals()`` and ``on_complete(result)``.
        """
        if self.active or getattr(self.store, "_runtime_transaction_owner", None) is not None:
            raise RuntimeTransactionError("runtime-transaction-busy")
        candidates = list(candidates)
        if len({id(candidate) for candidate in candidates}) != len(candidates):
            raise RuntimeTransactionError("duplicate-runtime-candidate")
        if not 0 < timeout <= 120:
            raise RuntimeTransactionError("invalid-runtime-deadline")
        self._thread_id = threading.get_ident()
        self._serial += 1
        serial = self._serial
        self.state, self.result = "staging", None
        self.store._runtime_transaction_owner = self
        self._mutate, self._publish = mutate, publish
        self._restore_runtime, self._retire_originals = restore_runtime, retire_originals
        self._on_complete, self._reason = on_complete, reason
        self._baseline = self._state_fingerprint(self.store.data)
        self._cancel_requested = self._commit_queued = False
        self._failure_code = None
        self._progress = {id(candidate): {"candidate": candidate, "generation": None, "pid": None,
                                         "spawned": False, "ready": False,
                                         "unsubscribe": None} for candidate in candidates}
        self._starting = True
        try:
            self._timer = self._schedule(timeout, lambda: self._deadline(serial))
            # Subscribe to every child before any launch can produce an event.
            for progress in self._progress.values():
                candidate = progress["candidate"]
                progress["unsubscribe"] = candidate.subscribe_lifecycle(
                    lambda event, candidate=candidate: self._event(serial, candidate, event))
            for progress in self._progress.values():
                if not self.active:
                    break
                candidate = progress["candidate"]
                generation = candidate.start_candidate()
                if type(generation) is not int or generation <= 0:
                    raise RuntimeTransactionError("candidate-generation-missing")
                if progress["generation"] not in (None, generation):
                    raise RuntimeTransactionError("candidate-generation-changed")
                progress["generation"] = generation
        except Exception:
            self._starting = False
            if self.active:
                self._abort("candidate-start-failed")
            return self
        self._starting = False
        self._maybe_commit(serial)
        return self

    def _event(self, serial, candidate, event):
        self._assert_thread()
        if serial != self._serial or not self.active:
            return
        progress = self._progress.get(id(candidate))
        if progress is None or not isinstance(event, dict):
            return
        generation = event.get("generation")
        current_generation = getattr(candidate, "generation", None)
        if type(generation) is not int or generation != current_generation:
            return
        if progress["generation"] not in (None, generation):
            return
        progress["generation"] = generation
        kind, pid = event.get("kind"), event.get("pid")
        if kind in ("failed", "exited"):
            if self.state == "committing":
                self._cancel_requested = True
                self._failure_code = "candidate-exited" if kind == "exited" else "candidate-failed"
            else:
                self._abort("candidate-exited" if kind == "exited" else "candidate-failed")
            return
        if kind == "spawned":
            if type(pid) is not int or pid <= 0 or getattr(candidate, "pid", None) != pid:
                return
            progress["spawned"], progress["pid"] = True, pid
            # Spawn proves only local process creation; no readiness transition.
            return
        if kind != "ready" or not progress["spawned"] or pid != progress["pid"]:
            return
        proof = event.get("proof") or {}
        token = getattr(candidate, "readiness_token", None)
        if (not isinstance(proof, dict) or proof.get("kind") != "tmux-client-attached"
                or not isinstance(token, str) or len(token) < 16 or proof.get("token") != token
                or proof.get("tmux") != candidate.record.get("tmux")
                or type(proof.get("clientPid")) is not int or proof["clientPid"] <= 0):
            return
        try:
            alive = candidate.is_candidate_alive(generation, pid)
        except Exception:
            alive = False
        if not alive:
            self._abort("candidate-exited")
            return
        progress["ready"] = True
        self._maybe_commit(serial)

    def _maybe_commit(self, serial):
        if (self._starting or serial != self._serial or self.state != "staging" or self._commit_queued
                or not all(progress["ready"] for progress in self._progress.values())):
            return
        self._commit_queued = True
        # Let already-pending VTE child-exited signals run before publishing.
        self._defer(lambda: self._commit(serial))

    def _all_alive(self):
        try:
            return all(progress["ready"] and progress["candidate"].is_candidate_alive(
                progress["generation"], progress["pid"]) for progress in self._progress.values())
        except Exception:
            return False

    def _commit(self, serial):
        self._assert_thread()
        if serial != self._serial or self.state != "staging":
            return False
        self._commit_queued = False
        if not self._all_alive():
            self._abort("candidate-exited")
            return False
        if self._state_fingerprint(self.store.data) != self._baseline:
            self._abort("runtime-state-changed")
            return False
        self.state = "committing"
        attempted_publish = False
        value = None
        try:
            with self.store.transaction(self._reason) as transaction:
                # CAS is checked again inside the persistent writer lease.
                if self._state_fingerprint(self.store.data) != self._baseline:
                    raise RuntimeTransactionError("runtime-state-changed")
                with transaction.step("runtime-model"):
                    value = self._mutate()
                if self._cancel_requested or not self._all_alive():
                    raise RuntimeTransactionError(self._failure_code or "candidate-exited")
                with transaction.step("runtime-publish"):
                    attempted_publish = True
                    self._publish([progress["candidate"] for progress in self._progress.values()], value)
                if self._cancel_requested or not self._all_alive():
                    raise RuntimeTransactionError(self._failure_code or "candidate-exited")
        except Exception as error:
            code = str(error) if isinstance(error, RuntimeTransactionError) else "runtime-transaction-failed"
            cleanup = self._stop_candidates()
            if attempted_publish:
                try:
                    self._restore_runtime()
                except Exception:
                    cleanup.append("runtime-rollback-failed")
            if self.store.journal_path.exists():
                cleanup.append("persistent-rollback-pending")
            self._finish(RuntimeTransactionResult(False, code, cleanup_errors=tuple(cleanup)))
            return False
        cleanup = []
        try:
            self._retire_originals()
        except Exception:
            # Durable publication succeeded. A retirement cleanup failure cannot
            # retarget the committed records to clients that have already stopped.
            cleanup.append("original-retirement-failed")
        self._finish(RuntimeTransactionResult(True, "committed", value, tuple(cleanup)))
        return False

    def cancel(self):
        """Cancel staging immediately, or request rollback at the next commit boundary."""
        self._assert_thread()
        if self.state == "committing":
            self._cancel_requested = True
            self._failure_code = "cancelled"
        elif self.state == "staging":
            self._abort("cancelled")

    def _deadline(self, serial):
        self._assert_thread()
        if serial == self._serial and self.active:
            self._timer = None
            if self.state == "committing":
                self._cancel_requested = True
                self._failure_code = "readiness-timeout"
            else:
                self._abort("readiness-timeout")
        return False

    def _stop_candidates(self):
        cleanup = []
        # Disconnect first: stopping a candidate may synchronously emit exited.
        self._unsubscribe()
        for progress in self._progress.values():
            # Even an unstarted adapter can own provisional widgets or private
            # connection references after another candidate failed synchronously.
            try:
                progress["candidate"].stop_candidate()
            except Exception:
                cleanup.append("candidate-stop-failed")
        return cleanup

    def _unsubscribe(self):
        for progress in self._progress.values():
            unsubscribe = progress.get("unsubscribe")
            progress["unsubscribe"] = None
            if unsubscribe is not None:
                try:
                    unsubscribe()
                except Exception:
                    pass

    def _abort(self, code):
        cleanup = self._stop_candidates()
        self._finish(RuntimeTransactionResult(False, code, cleanup_errors=tuple(cleanup)))

    def _finish(self, result):
        if not self.active:
            return
        self._unsubscribe()
        if self._timer is not None:
            self._cancel_timer(self._timer)
            self._timer = None
        self.result = result
        self.state = "committed" if result.success else result.code
        if getattr(self.store, "_runtime_transaction_owner", None) is self:
            self.store._runtime_transaction_owner = None
        callback = self._on_complete
        # Completed operations may remain available for diagnostics. Do not keep
        # import previews or endpoint credentials alive through callback closures.
        self._mutate = self._publish = self._restore_runtime = self._retire_originals = self._on_complete = None
        callback(result)
