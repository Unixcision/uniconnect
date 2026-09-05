"""Real asynchronous VTE/tmux publication in private state/display fixtures only."""

import copy
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
import uuid

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Vte", "2.91")
    from gi.repository import GLib, Gtk
    from uniconnect.runtime_transaction import RuntimeTransactionCoordinator
    from uniconnect.staged_terminal import StagedTerminal
    from uniconnect.state import StateStore
    from uniconnect.vault import Vault
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


@unittest.skipUnless(GTK_AVAILABLE and shutil.which("tmux"), "GTK/VTE display and tmux required")
class RealRuntimeTransactionTests(unittest.TestCase):
    def wait_for(self, predicate, timeout=10):
        if predicate():
            return
        loop = GLib.MainLoop()
        deadline = time.monotonic() + timeout
        errors = []

        def observe():
            try:
                if predicate():
                    loop.quit()
                    return False
                if time.monotonic() >= deadline:
                    raise AssertionError("isolated VTE fixture deadline expired")
                return True
            except BaseException as error:
                errors.append(error)
                loop.quit()
                return False

        GLib.timeout_add(15, observe)
        loop.run()
        if errors:
            raise errors[0]

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uniconnect-runtime-vte-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.socket = "uc-runtime-test-" + uuid.uuid4().hex[:12]
        self.clients, self.results, self.events = [], [], []
        self.gtk_window = None
        self.coordinator = None
        self.addCleanup(self.cleanup_runtime)
        environment = dict(os.environ)
        environment.pop("TMUX", None)
        environment.pop("TMUX_PANE", None)
        environment["TERM"] = "xterm-256color"
        subprocess.run(["tmux", "-L", self.socket, "-f", "/dev/null", "new-session", "-d",
                        "-s", "fixture", "-c", str(self.root), "/usr/bin/sleep 120"],
                       env=environment, check=True, capture_output=True, timeout=10)
        self.vault = Vault(self.root / "state")
        self.vault.initialize("private-vte-fixture-password")
        self.store = StateStore(self.root / "state", self.vault)
        self.record = {"id": "fixture-window", "name": "Fixture", "tmux": "fixture",
                       "tmuxSocket": self.socket, "cwd": str(self.root), "agent": "custom",
                       "commandArgv": ["/usr/bin/sleep", "120"], "paneId": "main"}
        self.workspace = {"id": "fixture-workspace", "name": "Original", "kind": "local",
                          "cwd": str(self.root), "windows": [self.record]}
        self.store.workspaces.append(self.workspace)
        self.store.save()
        self.owner = SimpleNamespace(store=self.store, font_scale=1.0, _=lambda text: text,
                                     _terminal_owners={}, _building_workspace=1,
                                     refresh_sidebar=lambda: None, persist=lambda: None,
                                     notify_window=lambda *_: None)
        self.gtk_window = Gtk.Window()
        self.gtk_window.set_default_size(800, 500)
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.gtk_window.add(self.box)
        self.gtk_window.show_all()
        self.original = self.make_candidate()
        original_events = []
        self.original.subscribe_lifecycle(original_events.append)
        self.original.start_candidate()
        self.wait_for(lambda: any(event["kind"] in ("ready", "failed", "exited") for event in original_events))
        self.assertEqual(original_events[-1]["kind"], "ready", original_events)
        self.original.adopt(self.workspace, self.record)
        self.original_pid = self.original.pid
        self.before_state, self.before_vault = self.store.path.read_bytes(), self.vault.path.read_bytes()
        self.before_model = copy.deepcopy(self.store.data)
        self.published = False
        self.restored = False
        self.coordinator = RuntimeTransactionCoordinator(
            self.store, schedule=lambda delay, callback: GLib.timeout_add(max(1, int(delay * 1000)), callback),
            cancel_timer=GLib.source_remove, defer=GLib.idle_add)

    def make_candidate(self):
        candidate = StagedTerminal(self.owner, self.workspace, self.record, registry={})
        self.clients.append(candidate)
        self.box.pack_start(candidate.surface, True, True, 0)
        self.gtk_window.show_all()
        return candidate

    def cleanup_runtime(self):
        if self.coordinator and self.coordinator.active:
            self.coordinator.cancel()
        for client in self.clients:
            client.stop_candidate()
        try:
            # VTE must consume spawn/exit callbacks before its widgets are freed.
            self.wait_for(lambda: all(not client.surface.pid and not client.surface._spawning
                                      and not client.surface._preparing for client in self.clients))
            self.wait_for(lambda: all(not client._probe_thread or not client._probe_thread.is_alive()
                                      for client in self.clients))
        finally:
            if self.gtk_window:
                self.gtk_window.destroy()
            subprocess.run(["tmux", "-L", self.socket, "kill-server"], capture_output=True, timeout=5)

    def tmux_client_pids(self):
        result = subprocess.run(["tmux", "-L", self.socket, "list-clients", "-F", "#{client_pid}"],
                                check=True, capture_output=True, text=True, timeout=5)
        return {int(pid) for pid in result.stdout.splitlines()}

    def mutate(self):
        self.workspace["name"] = "Published"
        return self.vault.put("ssh fixture@candidate.example.test")

    def publish(self, candidates, value):
        self.assertIn(self.original_pid, self.tmux_client_pids())
        self.assertFalse(self.original.surface.disposed)
        self.published = True
        for candidate in candidates:
            candidate.adopt(self.workspace, self.record)

    def restore(self):
        self.restored = True
        self.published = False
        # The original was never stopped; restore ownership after any partial adopt.
        self.original.adopt(self.workspace, self.record)

    def retire(self):
        self.assertTrue(self.published)
        self.assertFalse(self.store.journal_path.exists())
        self.original.stop_candidate()

    def start(self, candidate, **overrides):
        candidate.subscribe_lifecycle(self.events.append)
        callbacks = dict(mutate=self.mutate, publish=self.publish, restore_runtime=self.restore,
                         retire_originals=self.retire, on_complete=self.results.append, timeout=10)
        callbacks.update(overrides)
        self.coordinator.start([candidate], **callbacks)

    def test_real_vte_attachment_proof_precedes_commit_and_original_retirement(self):
        candidate = self.make_candidate()
        self.start(candidate)
        self.assertFalse(self.original.surface.disposed)
        self.wait_for(lambda: bool(self.results))
        self.assertTrue(self.results[0].success, self.results)
        kinds = [event["kind"] for event in self.events]
        self.assertLess(kinds.index("spawned"), kinds.index("ready"))
        proof = next(event["proof"] for event in self.events if event["kind"] == "ready")
        self.assertEqual(proof["kind"], "tmux-client-attached")
        self.assertEqual(proof["token"], candidate.readiness_token)
        self.assertEqual(proof["clientPid"], candidate.pid)
        self.assertIn(candidate.pid, self.tmux_client_pids())
        self.wait_for(lambda: self.original.pid == 0)
        self.assertNotIn(self.original_pid, self.tmux_client_pids())
        self.assertEqual(self.workspace["name"], "Published")
        self.assertNotEqual(self.record.get("runtimeState"), "stopped")
        self.assertEqual(StateStore(self.root / "state", self.vault).workspaces[0]["name"], "Published")

    def test_real_vte_partial_adoption_failure_preserves_original_and_exact_pair(self):
        candidate = self.make_candidate()

        def failed_publish(candidates, value):
            self.publish(candidates, value)
            raise OSError("private fixture UI publication failed")

        self.start(candidate, publish=failed_publish)
        self.wait_for(lambda: bool(self.results))
        self.assertFalse(self.results[0].success)
        self.assertTrue(self.restored)
        self.wait_for(lambda: candidate.pid == 0)
        self.assertIn(self.original_pid, self.tmux_client_pids())
        self.assertFalse(self.original.surface.disposed)
        self.assertEqual(self.store.path.read_bytes(), self.before_state)
        self.assertEqual(self.vault.path.read_bytes(), self.before_vault)
        self.assertEqual(self.store.data, self.before_model)
        self.assertIs(self.store.workspaces[0], self.workspace)
        self.assertIs(self.workspace["windows"][0], self.record)
        self.assertFalse(self.store.journal_path.exists())


if __name__ == "__main__":
    unittest.main()
