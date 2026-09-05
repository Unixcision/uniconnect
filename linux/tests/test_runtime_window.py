"""Full MainWindow runtime transactions on private GTK/state/tmux fixtures."""

import copy
from functools import wraps
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Vte", "2.91")
    from gi.repository import Gio, GLib, Gtk
    from uniconnect.state import StateStore
    from uniconnect.staged_terminal import StagedTerminal
    from uniconnect.vault import Vault
    from uniconnect.window import MainWindow
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


def isolated_application(method):
    """GTK/GApplication permits only one fully registered app per process here."""
    @wraps(method)
    def run(self):
        if os.environ.get("UNICONNECT_RUNTIME_WINDOW_CASE") == self._testMethodName:
            return method(self)
        socket = "uc-window-tx-test-" + uuid.uuid4().hex[:12]
        with tempfile.TemporaryDirectory(prefix="uniconnect-runtime-window-process-") as root:
            environment = dict(os.environ)
            environment.update(UNICONNECT_RUNTIME_WINDOW_CASE=self._testMethodName,
                               UNICONNECT_RUNTIME_WINDOW_SOCKET=socket,
                               UNICONNECT_RUNTIME_WINDOW_ROOT=root)
            environment["PYTHONPATH"] = os.pathsep.join(
                [str(Path(__file__).resolve().parents[1]), environment.get("PYTHONPATH", "")])
            try:
                result = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                                         type(self).__name__ + "." + self._testMethodName, "-v"],
                                        env=environment, capture_output=True, text=True, timeout=45)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            finally:
                # Exact fixture target, also cleaned if the child process crashes.
                subprocess.run(["tmux", "-L", socket, "kill-server"], capture_output=True, timeout=5)
    return run


@unittest.skipUnless(GTK_AVAILABLE and shutil.which("tmux"), "GTK/VTE display and tmux required")
class MainWindowRuntimeTransactionTests(unittest.TestCase):
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
                    raise AssertionError("isolated MainWindow runtime deadline expired")
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
        if os.environ.get("UNICONNECT_RUNTIME_WINDOW_CASE") != self._testMethodName:
            return
        self.temporary = tempfile.TemporaryDirectory(prefix="uniconnect-runtime-window-",
                                                     dir=os.environ["UNICONNECT_RUNTIME_WINDOW_ROOT"])
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.socket = os.environ["UNICONNECT_RUNTIME_WINDOW_SOCKET"]
        self.window, self.operation = None, None
        self.originals, self.candidates, self.results = {}, [], []
        self.addCleanup(self.cleanup_runtime)
        environment = dict(os.environ)
        environment.pop("TMUX", None)
        environment.pop("TMUX_PANE", None)
        environment["TERM"] = "xterm-256color"
        records = []
        for index, pane in enumerate(("main", "right")):
            name = "fixture-" + str(index)
            subprocess.run(["tmux", "-L", self.socket, "-f", "/dev/null", "new-session", "-d",
                            "-s", name, "-c", str(self.root), "/usr/bin/sleep 120"],
                           env=environment, check=True, capture_output=True, timeout=10)
            records.append({"id": name, "name": name, "cwd": str(self.root), "tmux": name,
                            "tmuxSocket": self.socket, "agent": "custom", "paneId": pane,
                            "commandArgv": ["/usr/bin/sleep", "120"]})
        self.vault = Vault(self.root / "state")
        self.vault.initialize("isolated-window-transaction-password")
        self.store = StateStore(self.root / "state", self.vault)
        self.workspace = {"id": "workspace-fixture", "name": "Original", "kind": "local",
                          "cwd": str(self.root), "windows": records, "splitAxis": "horizontal",
                          "selectedWindowId": records[0]["id"]}
        self.store.workspaces.append(self.workspace)
        self.store.data["selectedWorkspaceId"] = self.workspace["id"]
        self.store.data["settings"] = {"locale": "en", "autoLockMinutes": 0}
        self.store.save()
        # One application per child process, with a fixture-only identity.
        self.application = Gtk.Application(
            application_id="com.unixcision.uniconnect.runtimetest" + uuid.uuid4().hex,
            flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.application.register(None)
        self.window = MainWindow(self.application, self.store, self.vault)
        self.window.present()
        # The scheduled eight-second save is independently tested. Disable that
        # unrelated clock in this fixture so byte-exact rollback is deterministic.
        GLib.source_remove(self.window._tick_source)
        self.window._tick_source = 0
        self.wait_for(lambda: len(self.window.surfaces) == 2
                      and all(surface.pid > 0 for surface in self.window.surfaces.values()))
        self.originals = dict(self.window.surfaces)
        self.original_pids = {surface.pid for surface in self.originals.values()}
        self.wait_for(lambda: self.original_pids <= self.tmux_client_pids()
                      and self.window._sidebar_refresh == 0)
        # Drain initial layout/focus callbacks before capturing the intent snapshot.
        settled = []
        GLib.timeout_add(60, lambda: (settled.append(True), False)[1])
        self.wait_for(lambda: bool(settled) and self.window._sidebar_refresh == 0)
        self.store.save()
        self.before_state, self.before_vault = self.store.path.read_bytes(), self.vault.path.read_bytes()
        self.before_model = copy.deepcopy(self.store.data)
        self.before_registry = dict(self.window._terminal_owners)
        self.record_references = list(self.workspace["windows"])
        self.before_panes = self.tmux_panes()
        self.proposed = copy.deepcopy(self.workspace)
        self.proposed["name"] = "Published workspace"
        for record in self.proposed["windows"]:
            record["name"] = "Published " + record["id"]

    def cleanup_runtime(self):
        if self.operation and self.operation.active:
            self.operation.cancel()
        surfaces = list(self.originals.values()) + [candidate.surface for candidate in self.candidates]
        if self.window:
            surfaces.extend(self.window.surfaces.values())
            self.window.on_delete()
        for surface in surfaces:
            surface.dispose()
        try:
            self.wait_for(lambda: all(not surface.pid and not surface._spawning and not surface._preparing
                                      for surface in surfaces))
            self.wait_for(lambda: all(not candidate._probe_thread or not candidate._probe_thread.is_alive()
                                      for candidate in self.candidates))
        finally:
            if self.window:
                self.window.destroy()
            subprocess.run(["tmux", "-L", self.socket, "kill-server"], capture_output=True, timeout=5)

    def tmux_client_pids(self):
        result = subprocess.run(["tmux", "-L", self.socket, "list-clients", "-F", "#{client_pid}"],
                                check=True, capture_output=True, text=True, timeout=5)
        return {int(pid) for pid in result.stdout.splitlines()}

    def tmux_panes(self):
        return subprocess.check_output(["tmux", "-L", self.socket, "list-panes", "-a", "-F",
                                        "#{session_name}:#{pane_pid}"], text=True, timeout=5)

    def mutate(self):
        self.assertTrue(self.original_pids <= self.tmux_client_pids())
        self.assertTrue(all(not surface.disposed for surface in self.originals.values()))
        self.workspace["name"] = self.proposed["name"]
        for record, proposal in zip(self.workspace["windows"], self.proposed["windows"]):
            record["name"] = proposal["name"]
        return self.vault.put("ssh fixture@candidate.example.test")

    def start(self, mutate=None, **options):
        self.operation = self.window.stage_runtime(
            [self.proposed], {self.proposed["id"]: None}, mutate or self.mutate,
            reason="fixture-runtime-window", on_complete=self.results.append, **options)
        self.candidates = [progress["candidate"] for progress in self.operation._progress.values()]
        return self.operation

    def assert_restored(self):
        self.wait_for(lambda: all(not candidate.pid and not candidate.surface._spawning
                                  and not candidate.surface._preparing for candidate in self.candidates))
        self.assertEqual(self.tmux_client_pids(), self.original_pids)
        self.assertEqual(self.tmux_panes(), self.before_panes)
        self.assertTrue(all(not surface.disposed for surface in self.originals.values()))
        self.assertEqual(self.store.path.read_bytes(), self.before_state)
        self.assertEqual(self.vault.path.read_bytes(), self.before_vault)
        self.assertEqual(self.store.data, self.before_model)
        self.assertEqual(self.window._terminal_owners, self.before_registry)
        self.assertIs(self.store.workspaces[0], self.workspace)
        for reference in self.record_references:
            surface = self.window.surfaces[reference["id"]]
            self.assertIs(surface, self.originals[reference["id"]])
            self.assertIs(surface.record, reference)
            self.assertIs(surface.workspace, self.workspace)
            notebook = self.window.notebooks[(self.workspace["id"], reference["paneId"])]
            self.assertIs(surface.get_parent(), notebook)
            self.assertGreaterEqual(notebook.page_num(surface), 0)
        self.assertEqual(self.window.workspace_stack.get_visible_child_name(), self.workspace["id"])
        self.assertIn(self.window.focused_surface, self.originals.values())
        self.assertFalse(self.store.journal_path.exists())

    @isolated_application
    def test_success_adopts_proven_clients_and_only_then_retires_originals(self):
        self.start()
        self.assertTrue(all(not surface.disposed for surface in self.originals.values()))
        self.wait_for(lambda: bool(self.results))
        self.assertTrue(self.results[0].success, self.results)
        self.wait_for(lambda: all(surface.pid == 0 for surface in self.originals.values()))
        replacements = list(self.window.surfaces.values())
        self.assertEqual(len(replacements), 2)
        self.assertEqual(self.tmux_client_pids(), {surface.pid for surface in replacements})
        self.assertEqual(self.tmux_panes(), self.before_panes)
        for surface in replacements:
            self.assertIsNot(surface, self.originals[surface.record["id"]])
            self.assertFalse(surface.disposed)
            self.assertNotEqual(surface.record.get("runtimeState"), "stopped")
            self.assertIn(surface, self.window._terminal_owners.values())
        self.assertEqual(self.workspace["name"], "Published workspace")
        self.assertEqual(self.vault.get(self.results[0].value), "ssh fixture@candidate.example.test")
        loaded = StateStore(self.root / "state", self.vault)
        self.assertEqual(loaded.workspaces[0]["name"], "Published workspace")
        self.assertFalse(self.store.journal_path.exists())

    @isolated_application
    def test_mutation_failure_restores_vault_and_model_without_replacing_originals(self):
        def failed_mutation():
            self.mutate()
            raise OSError("isolated model mutation failure")

        self.start(mutate=failed_mutation)
        self.wait_for(lambda: bool(self.results))
        self.assertFalse(self.results[0].success)
        self.assert_restored()

    @isolated_application
    def test_save_failure_after_publication_restores_pages_registry_and_exact_pair(self):
        observed = {}

        def failpoint(stage):
            if stage == "commit:before":
                observed["published"] = all(self.window.surfaces[wid] is not original
                                            for wid, original in self.originals.items())
                observed["originals_alive"] = self.original_pids <= self.tmux_client_pids()
                raise OSError("isolated durable commit failure")

        self.store._failpoint = failpoint
        self.start()
        self.wait_for(lambda: bool(self.results))
        self.assertFalse(self.results[0].success)
        self.assertTrue(observed.get("published"), observed)
        self.assertTrue(observed.get("originals_alive"), observed)
        self.assert_restored()

    @isolated_application
    def test_partial_publication_failure_restores_the_original_surface_mapping(self):
        adopted = []
        actual_adopt = StagedTerminal.adopt

        def fail_second_adoption(candidate, workspace, record):
            if adopted:
                raise OSError("isolated second widget adoption failure")
            surface = actual_adopt(candidate, workspace, record)
            adopted.append(surface.record["id"])
            return surface

        with patch.object(StagedTerminal, "adopt", fail_second_adoption):
            self.start()
            self.wait_for(lambda: bool(self.results))
        self.assertEqual(len(adopted), 1)
        self.assertFalse(self.results[0].success)
        self.assert_restored()

    @isolated_application
    def test_cancel_after_actual_vte_spawn_preserves_originals_and_exact_pair(self):
        self.start()
        cancelled_after_spawn = []

        def cancel_on_spawn(event):
            if event["kind"] == "spawned" and self.operation.active:
                cancelled_after_spawn.append(event["pid"])
                self.operation.cancel()

        for candidate in self.candidates:
            candidate.subscribe_lifecycle(cancel_on_spawn)
        self.wait_for(lambda: bool(self.results))
        self.assertTrue(cancelled_after_spawn)
        self.assertEqual(self.results[0].code, "cancelled")
        self.assert_restored()


if __name__ == "__main__":
    unittest.main()
