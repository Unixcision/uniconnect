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
sys.path.insert(0, str(Path(__file__).resolve().parent))

from uniconnect.agent_tree import AgentTree
from uniconnect.state import StateStore
from uniconnect.transport import TransportError

from contracts_dir import contract

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
        self.surfaces = {}
        self.owner = SimpleNamespace(
            store=self.store, locked=False, _closed=False, _runtime_operation=None, surfaces=self.surfaces,
            vault=SimpleNamespace(locked=False),
            connection=lambda workspace: {"cred": "ssh root@167.233.192.135", "cred2": "ssh root@10.0.0.2"}[workspace["credentialId"]],
            background=lambda work, done: done(work()))
        self.tree = AgentTree(self.owner, transport=FakeTransport, clock=lambda: self.now[0], wall=lambda: 1790260204.0,
                              schedule=lambda seconds, callback: self.scheduled.append((seconds, callback)))

    def tearDown(self):
        self.directory.cleanup()

    def connect(self, *identifiers):
        """Superficies construidas con su cliente en marcha (lo que hace sondear una caja SSH)."""
        for identifier in identifiers:
            self.surfaces[identifier] = SimpleNamespace(disposed=False, pid=4321, status="Running",
                                                        update_status=lambda *args: None)

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
        self.connect("w-remote")
        FakeTransport.replies[("root@167.233.192.135", "default")] = {"sessions": [
            session("claudebets", agent=agent("claude", NEW_ID, "/root/xunis", as_root=True))]}
        self.tree.poll()
        record = self.saved("w-remote")
        self.assertEqual((record["sessionId"], record["asRoot"], record["resumeCwd"]), (NEW_ID, True, "/root/xunis"))
        self.assertEqual([item["sessionId"] for item in record["history"]], [CLAUDE_ID, NEW_ID])

    def test_shell_keeps_last_agent_and_ambiguous_or_missing_id_change_nothing(self):
        self.connect("w-remote")
        before = copy.deepcopy(self.remote)
        for reply in (session("claudebets", "identidad_ambigua"), session("claudebets", "sin_id", agent("claude", None)),
                      session("claudebets", "panel_muerto"), dict(session("claudebets", "sin_ia"), live=False)):
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
        self.connect("w-remote")
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
        self.connect("w-remote")
        self.tree.poll()
        self.now[0] += 8
        self.tree.poll()
        keys = [call[0] for call in FakeTransport.calls]
        self.assertEqual(keys.count(("local", "uniconnect-local")), 2)
        self.assertEqual(keys.count(("root@167.233.192.135", "default")), 1)
        self.now[0] += 60
        self.tree.poll()
        self.assertEqual([call[0] for call in FakeTransport.calls].count(("root@167.233.192.135", "default")), 2)

    def test_local_always_and_ssh_only_with_a_connected_window_never_twice_at_once(self):
        pending = []
        self.owner.background = lambda work, done: pending.append((work, done))
        # Sin ventanas SSH conectadas solo se lee el equipo local: nada de SSH a cajas sin usar.
        self.assertEqual(self.tree.poll(), [("local", "uniconnect-local")])
        self.connect("w-remote", "w-other")
        self.surfaces["w-other"].pid = 0  # Construida pero sin cliente (desconectada): no cuenta.
        self.assertEqual(self.tree.poll(force=True), [("box-ssh", "default")])
        self.surfaces["w-other"].pid = 99
        self.assertEqual(self.tree.poll(force=True), [("box-ssh-2", "uniconnect")])
        for work, done in pending:
            done(work())
        self.assertEqual(sorted(call[0] for call in FakeTransport.calls),
                         sorted([("local", "uniconnect-local"), ("root@167.233.192.135", "default"), ("root@10.0.0.2", "uniconnect")]))
        self.assertEqual(FakeTransport.calls[0][1][:2], ["--socket", "uniconnect-local"])
        self.assertIn("--session", FakeTransport.calls[0][1])

    def test_locked_vault_transaction_or_lock_skip_the_probe(self):
        self.connect("w-remote", "w-other")
        self.owner.vault.locked = True
        self.tree.poll()
        self.assertEqual([call[0] for call in FakeTransport.calls], [("local", "uniconnect-local")])
        self.owner.locked = True
        self.assertEqual(self.tree.poll(force=True), [])

    def test_refresh_all_calls_back_even_when_probe_fails_or_times_out(self):
        self.connect("w-remote")
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

    def test_client_exit_is_interrupted_only_when_the_server_died_with_the_agent_seen_recently(self):
        # D5: nunca por una salida limpia del cliente (shell que sale, cerrar, terminar tmux).
        workspace = self.store.workspaces[0]
        for server_died, recent, interrupted in ((True, True, True), (False, True, None), (True, False, None)):
            with self.subTest(server_died=server_died, recent=recent):
                record = dict(self.local, runtimeState="agent", agent="claude", sessionId=NEW_ID)
                AgentTree.client_exited(workspace, record, server_died=server_died, recent=recent)
                self.assertEqual((record["runtimeState"], record.get("interrupted")), ("stopped", interrupted))
        shell = dict(self.local, runtimeState="shell")
        AgentTree.client_exited(workspace, shell, server_died=True, recent=True)
        self.assertEqual((shell["runtimeState"], shell.get("interrupted")), ("stopped", None))
        remote = dict(self.remote)
        AgentTree.client_exited(self.store.workspaces[1], remote, server_died=True, recent=True)
        self.assertEqual(remote["runtimeState"], "agent")

    def seen_running(self):
        self.local.update(agent="claude", sessionId=NEW_ID, runtimeState="agent", resumeCwd="/work", agentSource="ficha",
                          asRoot=False)
        self.store.save()
        FakeTransport.replies[("local", "uniconnect-local")] = {"sessions": [session("uc-local", agent=agent("claude", NEW_ID))]}
        self.tree.poll(force=True)
        self.assertTrue(self.tree.agent_recent(self.store.workspaces[0], self.local))

    def test_session_lost_one_tick_after_the_agent_was_seen_is_interrupted(self):
        self.seen_running()
        FakeTransport.replies[("local", "uniconnect-local")] = {"server": False, "sessions": []}  # Servidor caído.
        self.now[0] += 8
        self.tree.poll()
        self.assertEqual((self.saved("w-local")["runtimeState"], self.saved("w-local")["interrupted"]), ("stopped", True))

    def test_a_missing_session_with_the_server_alive_is_not_interrupted(self):
        # D5, igual que el Mac: con el servidor vivo (tiene otra sesión), que falte esta es lo mismo
        # que un /exit seguido de exit o Ctrl+D. No se marca: no se reanuda sola al abrir.
        self.seen_running()
        FakeTransport.replies[("local", "uniconnect-local")] = {"sessions": [session("otra")]}
        self.now[0] += 8
        self.tree.poll()
        self.assertFalse(self.saved("w-local").get("interrupted"))

    def test_stale_observation_truncated_read_or_deliberate_close_never_interrupt(self):
        self.seen_running()
        FakeTransport.replies[("local", "uniconnect-local")] = {"sessions": [], "truncated": True}
        self.now[0] += 8
        self.tree.poll()  # Con truncated, que falte no dice nada.
        self.assertFalse(self.saved("w-local").get("interrupted"))
        FakeTransport.replies[("local", "uniconnect-local")] = {"server": False, "sessions": []}
        self.now[0] += 8
        self.tree.poll()  # La IA se vio hace dos ticks: no es una observación reciente.
        self.assertFalse(self.saved("w-local").get("interrupted"))
        self.seen_running()
        self.tree.mark_closed_by_user(self.local)
        self.now[0] += 8
        self.tree.poll()
        self.assertFalse(self.saved("w-local").get("interrupted"))

    def test_remote_recovery_needs_a_recent_live_read_and_no_deliberate_mark(self):
        # D6: ≤ 2 ticks (120 s) desde la última lectura que la vio y sin marca de cierre deliberado.
        self.connect("w-remote")
        self.assertFalse(self.tree.remote_resume_allowed(self.remote))  # Nunca vista (p. ej. al arrancar).
        FakeTransport.replies[("root@167.233.192.135", "default")] = {"sessions": [session("claudebets", agent=agent("claude", CLAUDE_ID))]}
        self.tree.poll()
        self.assertTrue(self.tree.remote_resume_allowed(self.remote))
        self.now[0] += 121.5
        self.assertFalse(self.tree.remote_resume_allowed(self.remote))
        self.tree.poll()
        self.assertTrue(self.tree.remote_resume_allowed(self.remote))
        self.tree.mark_closed_by_user(self.remote)
        self.assertFalse(self.tree.remote_resume_allowed(self.remote))
        self.now[0] += 60
        self.tree.poll()  # Vuelve a verse: la marca se va.
        self.assertTrue(self.tree.remote_resume_allowed(self.remote))
        # missing_is_deliberate: el servidor sigue con otras sesiones y falta solo esta.
        FakeTransport.replies[("root@167.233.192.135", "default")] = {"server": True, "sessions": []}
        self.now[0] += 60
        self.tree.poll()
        self.assertFalse(self.tree.remote_resume_allowed(self.remote))

    def test_each_session_of_the_shared_example_has_its_contract_effect(self):
        # contracts/agent-tree-v1/sonda-lectura.json: qué hace el lector con cada sesión de sonda-salida.json.
        output = json.loads(contract("agent-tree-v1", "sonda-salida.json").read_text(encoding="utf-8"))
        effects = json.loads(contract("agent-tree-v1", "sonda-lectura.json").read_text(encoding="utf-8"))["sesiones"]
        entries = {item["name"]: item for item in output["sessions"]}
        old = "0d8f0000-0000-4000-8000-000000000000"
        for effect in effects:
            with self.subTest(sesion=effect["sesion"]):
                record = {"id": "w", "name": effect["sesion"], "tmux": effect["sesion"], "cwd": "/root", "agent": "claude",
                          "sessionId": old, "runtimeState": "agent"}
                before = copy.deepcopy(record)
                changed = self.tree.transition(record, entries[effect["sesion"]])
                if effect["efecto"] == "ia":
                    self.assertTrue(changed)
                    self.assertEqual((record["agent"], record["sessionId"], record["resumeCwd"], record["asRoot"],
                                      record["agentSource"], record["runtimeState"]),
                                     (effect["provider"], effect["session_id"], effect["cwd"], effect["as_root"],
                                      effect["source"], "agent"))
                    self.assertIn(old, [item["sessionId"] for item in record["history"]])
                elif effect["efecto"] == "shell":
                    self.assertTrue(changed)
                    self.assertEqual((record["runtimeState"], record["sessionId"]), ("shell", old))
                else:  # sin_id y nada: lo guardado no se toca.
                    self.assertFalse(changed)
                    self.assertEqual(record, before)

    def test_a_conversation_already_owned_by_another_window_is_not_copied(self):
        # XUNIS: la misma conversación corriendo en dos ventanas no se anota en la segunda.
        FakeTransport.replies[("local", "uniconnect-local")] = {"sessions": [
            session("uc-local", agent=agent("claude", CLAUDE_ID.upper()))]}
        with patch.object(self.store, "save") as save:
            self.tree.poll()
            save.assert_not_called()
        self.assertNotIn("sessionId", self.local)
        self.assertEqual(self.tree.live["w-local"]["session"]["agent"]["session_id"], CLAUDE_ID.upper())

    def test_interrupted_is_cleared_when_the_agent_is_seen_again(self):
        self.local.update(agent="claude", sessionId=NEW_ID, runtimeState="stopped", interrupted=True, resumeCwd="/work",
                          agentSource="ficha", asRoot=False)
        self.store.save()
        FakeTransport.replies[("local", "uniconnect-local")] = {"sessions": [session("uc-local", agent=agent("claude", NEW_ID))]}
        self.tree.poll()
        self.assertEqual((self.saved("w-local")["runtimeState"], self.saved("w-local")["interrupted"]), ("agent", False))


if __name__ == "__main__":
    unittest.main()
