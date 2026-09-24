"""Árbol IA vivo con un transporte falso que devuelve el JSON de la sonda; el guardado es real."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.agent_tree import AgentTree
from uniconnect.state import StateStore
from uniconnect.transport import TransportError

CLAUDE_ID = "473ed1de-4397-45ef-b00b-6b17fd7382b0"
NEW_ID = "714b0eae-b568-4e0c-a70b-c87c0d0a801a"
CODEX_ID = "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17"


def session(name, reason=None, agent=None):
    return {"name": name, "session_id": "$1", "pane_id": "%1", "live": True, "reason": reason, "agent": agent}


def agent(provider, session_id, cwd="/work", source="ficha", as_root=False):
    return {"provider": provider, "session_id": session_id, "cwd": cwd, "as_root": as_root, "source": source}


class FakeTransport:
    """Registra cada lectura; ``replies`` decide qué devuelve la sonda por (destino, socket)."""

    calls = []
    replies = {}

    def __init__(self, command=None, *, socket_name=None):
        self.command, self.socket_name = command, socket_name

    def run_python(self, source, args, *, timeout):
        key = (self.command.destination if self.command else "local", self.socket_name)
        FakeTransport.calls.append((key, list(args), timeout))
        reply = FakeTransport.replies.get(key, {"sessions": []})
        if isinstance(reply, Exception):
            raise reply
        payload = {"version": 1, "checked_at": "2026-09-24T14:30:04Z", "socket": self.socket_name, "error": None,
                   **reply}
        return subprocess.CompletedProcess([], 0, "banner del perfil\n" + json.dumps(payload) + "\n", "")


class TreeFixture(unittest.TestCase):
    def setUp(self):
        FakeTransport.calls, FakeTransport.replies = [], {}
        self.directory = tempfile.TemporaryDirectory(prefix="uc-agent-tree-")
        self.store = StateStore(Path(self.directory.name) / "state")
        self.local = {"id": "w-local", "name": "MULTIGRAM", "tmux": "uc-local", "tmuxSocket": "uniconnect-local",
                      "cwd": "/work", "agent": "shell"}
        self.remote = {"id": "w-remote", "name": "claudebets", "tmux": "claudebets", "tmuxSocket": "default",
                       "cwd": "/root", "agent": "claude", "sessionId": CLAUDE_ID, "runtimeState": "agent"}
        self.store.data["workspaces"] = [
            {"id": "box-local", "name": "PROYECTOS", "kind": "local", "cwd": "/work", "windows": [self.local]},
            {"id": "box-ssh", "name": "XUNIS", "kind": "ssh", "credentialId": "cred", "windows": [self.remote]},
            {"id": "box-ssh-2", "name": "Otra", "kind": "ssh", "credentialId": "cred2",
             "windows": [{"id": "w-other", "name": "hgabot", "tmux": "hgabot", "cwd": "/root", "agent": "shell"}]}]
        self.store.save()
        self.now = [1000.0]
        self.scheduled = []
        self.owner = SimpleNamespace(
            store=self.store, locked=False, _closed=False, _runtime_operation=None, surfaces={},
            vault=SimpleNamespace(locked=False),
            connection=lambda workspace: {"cred": "ssh root@167.233.192.135", "cred2": "ssh root@10.0.0.2"}[workspace["credentialId"]],
            background=lambda work, done: done(work()))
        self.tree = AgentTree(self.owner, transport=FakeTransport, clock=lambda: self.now[0], wall=lambda: 1790260204.0,
                              schedule=lambda seconds, callback: self.scheduled.append((seconds, callback)))

    def tearDown(self):
        self.directory.cleanup()

    def saved(self, identifier):
        disk = StateStore(Path(self.directory.name) / "state")
        return next(record for workspace in disk.workspaces for record in workspace["windows"] if record["id"] == identifier)


class AgentTreeTests(TreeFixture):
    def test_detected_agent_is_persisted_with_all_fields(self):
        FakeTransport.replies[("local", "uniconnect-local")] = {"sessions": [
            session("uc-local", agent=agent("codex", CODEX_ID, "/work/multigram", "rollout"))]}
        self.tree.poll()
        record = self.saved("w-local")
        self.assertEqual({key: record.get(key) for key in ("agent", "sessionId", "resumeCwd", "asRoot", "agentSource",
                                                           "agentObservedAt", "runtimeState", "interrupted")},
                         {"agent": "codex", "sessionId": CODEX_ID, "resumeCwd": "/work/multigram", "asRoot": False,
                          "agentSource": "rollout", "agentObservedAt": 1790260204.0, "runtimeState": "agent",
                          "interrupted": False})
        self.assertEqual([(item["agent"], item["sessionId"], item["cwd"]) for item in record["history"]],
                         [("codex", CODEX_ID, "/work/multigram")])
        self.assertEqual(self.tree.live["w-local"]["session"]["agent"]["session_id"], CODEX_ID)
        # Otra lectura igual no vuelve a guardar.
        with patch.object(self.store, "save") as save:
            self.now[0] += 8
            self.tree.poll()
            save.assert_not_called()

    def test_changed_conversation_enters_and_old_one_stays_in_history(self):
        FakeTransport.replies[("root@167.233.192.135", "default")] = {"sessions": [
            session("claudebets", agent=agent("claude", NEW_ID, "/root/xunis", as_root=True))]}
        self.tree.poll()
        record = self.saved("w-remote")
        self.assertEqual((record["sessionId"], record["asRoot"], record["resumeCwd"]), (NEW_ID, True, "/root/xunis"))
        self.assertEqual([item["sessionId"] for item in record["history"]], [CLAUDE_ID, NEW_ID])

    def test_shell_keeps_last_agent_and_ambiguous_or_missing_id_change_nothing(self):
        before = copy.deepcopy(self.remote)
        for reply in (session("claudebets", "identidad_ambigua"), session("claudebets", "sin_id", agent("claude", None)),
                      session("claudebets", "panel_muerto")):
            FakeTransport.replies[("root@167.233.192.135", "default")] = {"sessions": [reply]}
            with patch.object(self.store, "save") as save:
                self.tree.poll(force=True)
                save.assert_not_called()
            self.assertEqual(self.remote, before)
        FakeTransport.replies[("root@167.233.192.135", "default")] = {"sessions": [session("claudebets", "sin_ia")]}
        self.tree.poll(force=True)
        record = self.saved("w-remote")
        self.assertEqual((record["runtimeState"], record["agent"], record["sessionId"]), ("shell", "claude", CLAUDE_ID))

    def test_missing_session_or_failed_probe_changes_nothing(self):
        before = copy.deepcopy(self.store.data)
        FakeTransport.replies[("root@167.233.192.135", "default")] = TransportError("connection_timeout")
        FakeTransport.replies[("local", "uniconnect-local")] = {"sessions": []}
        self.tree.poll()
        self.assertEqual(self.store.data["workspaces"], before["workspaces"])
        self.assertFalse(self.tree.live["w-remote"]["ok"])
        self.assertIsNone(self.tree.live["w-local"]["session"])

    def test_failed_save_restores_every_record(self):
        FakeTransport.replies[("local", "uniconnect-local")] = {"sessions": [session("uc-local", agent=agent("claude", NEW_ID))]}
        before = copy.deepcopy(self.local)
        with patch.object(self.store, "save", side_effect=OSError("disco lleno")):
            self.tree.poll()
        self.assertEqual(self.local, before)
        self.assertNotIn("sessionId", self.saved("w-local"))

    def test_ssh_is_not_repeated_before_sixty_seconds_but_local_every_tick(self):
        self.tree.poll()
        self.now[0] += 8
        self.tree.poll()
        keys = [call[0] for call in FakeTransport.calls]
        self.assertEqual(keys.count(("local", "uniconnect-local")), 2)
        self.assertEqual(keys.count(("root@167.233.192.135", "default")), 1)
        self.now[0] += 60
        self.tree.poll()
        self.assertEqual([call[0] for call in FakeTransport.calls].count(("root@167.233.192.135", "default")), 2)

    def test_every_box_is_probed_not_only_the_selected_one_and_never_twice_at_once(self):
        pending = []
        self.owner.background = lambda work, done: pending.append((work, done))
        self.assertEqual(len(self.tree.poll()), 3)  # Local, XUNIS y la otra caja SSH (con su socket por defecto).
        self.assertEqual(self.tree.poll(force=True), [])
        for work, done in pending:
            done(work())
        self.assertEqual(sorted(call[0] for call in FakeTransport.calls),
                         sorted([("local", "uniconnect-local"), ("root@167.233.192.135", "default"), ("root@10.0.0.2", "uniconnect")]))
        self.assertEqual(FakeTransport.calls[0][1][:2], ["--socket", "uniconnect-local"])
        self.assertIn("--session", FakeTransport.calls[0][1])

    def test_locked_vault_transaction_or_lock_skip_the_probe(self):
        self.owner.vault.locked = True
        self.tree.poll()
        self.assertEqual([call[0] for call in FakeTransport.calls], [("local", "uniconnect-local")])
        self.owner.locked = True
        self.assertEqual(self.tree.poll(force=True), [])

    def test_refresh_all_calls_back_even_when_probe_fails_or_times_out(self):
        FakeTransport.replies[("root@167.233.192.135", "default")] = TransportError("connection_timeout")
        calls = []
        self.tree.refresh_all(lambda: calls.append("guardado"))
        self.assertEqual(calls, ["guardado"])
        pending = []
        self.owner.background = lambda work, done: pending.append((work, done))
        self.tree.refresh_all(lambda: calls.append("tarde"))
        self.assertEqual(calls, ["guardado"])
        seconds, deadline = self.scheduled[-1]
        self.assertEqual(seconds, 10)
        deadline()
        self.assertEqual(calls, ["guardado", "tarde"])
        for work, done in pending:
            done(work())
        self.assertEqual(calls, ["guardado", "tarde"])  # Una sola vez.
        self.owner.locked = True
        self.tree.refresh_all(lambda: calls.append("bloqueado"))
        self.assertEqual(calls[-1], "bloqueado")

    def test_client_exit_with_active_agent_leaves_it_interrupted(self):
        workspace = self.store.workspaces[0]
        record = dict(self.local, runtimeState="agent", agent="claude", sessionId=NEW_ID)
        AgentTree.client_exited(workspace, record)
        self.assertEqual((record["runtimeState"], record["interrupted"]), ("stopped", True))
        shell = dict(self.local, runtimeState="shell")
        AgentTree.client_exited(workspace, shell)
        self.assertEqual(shell["runtimeState"], "stopped")
        self.assertNotIn("interrupted", shell)
        remote = dict(self.remote)
        AgentTree.client_exited(self.store.workspaces[1], remote)
        self.assertEqual(remote["runtimeState"], "agent")

    def test_interrupted_is_cleared_when_the_agent_is_seen_again(self):
        self.local.update(agent="claude", sessionId=NEW_ID, runtimeState="stopped", interrupted=True, resumeCwd="/work",
                          agentSource="ficha", asRoot=False)
        self.store.save()
        FakeTransport.replies[("local", "uniconnect-local")] = {"sessions": [session("uc-local", agent=agent("claude", NEW_ID))]}
        self.tree.poll()
        self.assertEqual((self.saved("w-local")["runtimeState"], self.saved("w-local")["interrupted"]), ("agent", False))


if __name__ == "__main__":
    unittest.main()
