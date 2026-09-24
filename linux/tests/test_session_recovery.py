"""Recuperación de sesiones tmux perdidas con un transporte falso: qué se recrea, cómo y qué no se toca."""

import copy
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.session_recovery import SessionRecovery
from uniconnect.transport import TmuxCommand, TransportError

CLAUDE_ID = "473ed1de-4397-45ef-b00b-6b17fd7382b0"
CODEX_ID = "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17"


class FakeTransport:
    alive = {}
    failures = {}
    created = []

    def __init__(self, command=None, *, socket_name=None):
        self.key = (command.destination if command else "local", socket_name)

    def list_sessions(self):
        failure = FakeTransport.failures.get(("list",) + self.key)
        if failure:
            raise failure
        return [{"name": name, "clients": 0, "windows": 1} for name in FakeTransport.alive.get(self.key, ())]

    def ensure_session(self, window):
        TmuxCommand.validate_window(window)  # La ventana efectiva tiene que ser lanzable.
        failure = FakeTransport.failures.get(("ensure", window["tmux"]))
        if failure:
            raise failure
        FakeTransport.created.append((self.key, copy.deepcopy(window)))
        return {"tmux": window["tmux"], "created": True}


class RecoveryFixture(unittest.TestCase):
    def setUp(self):
        FakeTransport.alive, FakeTransport.failures, FakeTransport.created = {}, {}, []
        self.agent = {"id": "w-agent", "name": "MULTIGRAM", "tmux": "uc-agent", "tmuxSocket": "uniconnect-local",
                      "cwd": "/work", "agent": "claude", "sessionId": CLAUDE_ID, "runtimeState": "agent",
                      "resumeCwd": "/work/multigram", "model": "opus"}
        self.interrupted = {"id": "w-int", "name": "codex", "tmux": "uc-int", "tmuxSocket": "uniconnect-local",
                            "cwd": "/work", "agent": "codex", "sessionId": CODEX_ID, "runtimeState": "stopped",
                            "interrupted": True}
        self.shell = {"id": "w-shell", "name": "shell", "tmux": "uc-shell", "tmuxSocket": "uniconnect-local",
                      "cwd": "/work", "agent": "claude", "sessionId": CLAUDE_ID, "runtimeState": "shell"}
        self.custom = {"id": "w-custom", "name": "custom", "tmux": "uc-custom", "cwd": "/work", "agent": "custom",
                       "commandArgv": ["claude", "--resume", "viejo"]}
        self.alive = {"id": "w-alive", "name": "vivo", "tmux": "uc-alive", "cwd": "/work", "agent": "claude",
                      "sessionId": CLAUDE_ID, "runtimeState": "agent"}
        self.remote = {"id": "w-remote", "name": "claudebets", "tmux": "claudebets", "tmuxSocket": "default",
                       "cwd": "/root", "agent": "claude", "sessionId": CLAUDE_ID, "runtimeState": "agent"}
        self.other = {"id": "w-other", "name": "hgabot", "tmux": "hgabot", "cwd": "/root", "agent": "shell"}
        self.workspaces = [
            {"id": "local", "name": "PROYECTOS", "kind": "local",
             "windows": [self.agent, self.interrupted, self.shell, self.custom, self.alive]},
            {"id": "ssh-a", "name": "XUNIS", "kind": "ssh", "credentialId": "a", "windows": [self.remote]},
            {"id": "ssh-b", "name": "Otra", "kind": "ssh", "credentialId": "b", "windows": [self.other]}]
        closed = {"id": "c1", "kind": "window", "window": {"id": "w-closed", "tmux": "uc-closed", "cwd": "/work",
                                                          "agent": "claude", "sessionId": CLAUDE_ID, "runtimeState": "agent"}}
        self.surfaces = {}
        self.pending = []
        self.owner = SimpleNamespace(
            store=SimpleNamespace(workspaces=self.workspaces, closed=[closed]),
            vault=SimpleNamespace(locked=False), surfaces=self.surfaces,
            connection=lambda workspace: {"a": "ssh root@167.233.192.135", "b": "ssh root@10.0.0.2"}[workspace["credentialId"]],
            background=lambda work, done: done(work()))
        self.recovery = SessionRecovery(self.owner, transport=FakeTransport)
        FakeTransport.alive[("local", "uniconnect-local")] = ["uc-alive"]

    def created(self):
        return {window["tmux"]: window for _, window in FakeTransport.created}


class RunAllTests(RecoveryFixture):
    def test_missing_sessions_are_recreated_with_the_right_effective_window(self):
        self.recovery.run_all(SessionRecovery.snapshot(self.owner.store))
        created = self.created()
        agent = created["uc-agent"]
        self.assertEqual((agent["agent"], agent["sessionId"], agent["resumeCwd"], agent["cwd"]),
                         ("claude", CLAUDE_ID, "/work/multigram", "/work"))
        self.assertIn("--resume " + CLAUDE_ID, TmuxCommand.pane_command(agent))
        self.assertIn("uc_guard", TmuxCommand.pane_command(agent))
        self.assertEqual((created["uc-int"]["agent"], created["uc-int"]["sessionId"]), ("codex", CODEX_ID))
        for name in ("uc-shell", "uc-custom", "hgabot"):
            self.assertEqual(created[name]["agent"], "shell", name)
            self.assertNotIn("sessionId", created[name])
            self.assertNotIn("commandArgv", created[name])
        self.assertEqual(created["claudebets"]["sessionId"], CLAUDE_ID)

    def test_live_and_closed_sessions_are_never_touched(self):
        self.recovery.run_all(SessionRecovery.snapshot(self.owner.store))
        self.assertNotIn("uc-alive", self.created())
        self.assertNotIn("uc-closed", self.created())
        self.workspaces[0]["windows"].append({"id": "w-closed", "tmux": "uc-closed", "cwd": "/work", "agent": "shell"})
        self.recovery.run_all({})
        self.assertNotIn("uc-closed", self.created())

    def test_snapshot_taken_before_launch_keeps_the_agent_even_if_the_record_changed_after(self):
        snapshot = SessionRecovery.snapshot(self.owner.store)
        # Lo que hacen _prepared (carpeta ausente) y on_exit al arrancar las superficies.
        self.agent["runtimeState"] = "shell"
        self.recovery.run_all(snapshot)
        self.assertEqual(self.created()["uc-agent"]["sessionId"], CLAUDE_ID)
        FakeTransport.created = []
        self.recovery.run_all(SessionRecovery.snapshot(self.owner.store))
        self.assertEqual(self.created()["uc-agent"]["agent"], "shell")

    def test_one_failing_ssh_box_does_not_stop_the_others(self):
        FakeTransport.failures[("list", "root@167.233.192.135", "default")] = TransportError("connection_timeout")
        self.recovery.run_all(SessionRecovery.snapshot(self.owner.store))
        self.assertNotIn("claudebets", self.created())
        self.assertIn("hgabot", self.created())
        self.assertIn("uc-agent", self.created())
        self.assertIn(("ssh-a", "group_failed", "connection_timeout"), self.recovery.events)

    def test_locked_vault_skips_ssh_without_prompting(self):
        self.owner.vault.locked = True
        self.owner.connection = lambda workspace: self.fail("no se debe pedir la bóveda")
        self.recovery.run_all(SessionRecovery.snapshot(self.owner.store))
        self.assertEqual({key[0] for key, _ in FakeTransport.created}, {"local"})

    def test_duplicate_owner_is_skipped_and_recorded_without_raising(self):
        FakeTransport.failures[("ensure", "uc-agent")] = TransportError("duplicate_agent_owner", CLAUDE_ID)
        self.recovery.run_all(SessionRecovery.snapshot(self.owner.store))
        self.assertNotIn("uc-agent", self.created())
        self.assertIn(("w-agent", "duplicate_agent_owner", CLAUDE_ID), self.recovery.events)
        self.assertIn("uc-int", self.created())
        self.assertEqual(self.recovery.inflight, {})

    def test_notice_reaches_an_existing_surface(self):
        self.surfaces["w-agent"] = SimpleNamespace(disposed=False, recovery_notice=None)
        self.recovery.run_all(SessionRecovery.snapshot(self.owner.store))
        self.assertEqual(self.surfaces["w-agent"].recovery_notice, "Sesión tmux recreada; reanudando Claude Code 473ed1de")


class MissingSessionExitTests(RecoveryFixture):
    def surface(self, record, workspace):
        surface = SimpleNamespace(record=record, workspace=workspace, generation=3, disposed=False, pid=0,
                                  _pending_launch=None, launches=0)

        def launch():
            surface.launches += 1
            surface.generation += 1
        surface.launch = launch
        return surface

    def test_exit_72_recovers_once_per_generation(self):
        surface = self.surface(self.agent, self.workspaces[0])
        self.assertTrue(self.recovery.on_missing_session(surface))
        self.assertEqual((surface.launches, surface.generation), (1, 4))
        self.assertEqual(self.created()["uc-agent"]["sessionId"], CLAUDE_ID)
        # El cliente relanzado vuelve a salir con 72: queda Desconectada, sin otra recuperación.
        self.assertFalse(self.recovery.on_missing_session(surface))
        self.assertEqual(surface.launches, 1)
        # Una reconexión explícita (nueva generación) sí puede recuperar otra vez.
        surface.generation += 1
        self.assertTrue(self.recovery.on_missing_session(surface))

    def test_exit_72_during_startup_recovery_waits_for_it(self):
        self.owner.background = lambda work, done: self.pending.append((work, done))
        self.recovery.run_all(SessionRecovery.snapshot(self.owner.store))
        surface = self.surface(self.agent, self.workspaces[0])
        self.assertTrue(self.recovery.on_missing_session(surface))
        self.assertEqual(surface.launches, 0)
        for work, done in list(self.pending):
            done(work())
        self.assertEqual(surface.launches, 1)
        self.assertEqual([window["tmux"] for _, window in FakeTransport.created].count("uc-agent"), 1)

    def test_disposed_or_replaced_client_is_not_relaunched(self):
        self.owner.background = lambda work, done: self.pending.append((work, done))
        surface = self.surface(self.agent, self.workspaces[0])
        self.recovery.on_missing_session(surface)
        surface.disposed = True
        for work, done in self.pending:
            done(work())
        self.assertEqual(surface.launches, 0)

    def test_window_without_tmux_is_not_recovered(self):
        record = {"id": "legacy", "name": "pty", "cwd": "/work", "agent": "shell"}
        self.assertFalse(self.recovery.on_missing_session(self.surface(record, self.workspaces[0])))


if __name__ == "__main__":
    unittest.main()
