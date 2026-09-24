"""Detalles de ventana (window_details.v1): JSON del contrato, filas del modal y los tres menús."""

import calendar
import json
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from uniconnect.resume_catalog import AgentResumeCatalog
from uniconnect.window_details import LIVE_REASONS, WindowDetails

from contracts_dir import contract

CLAUDE_ID = "473ed1de-4397-45ef-b00b-6b17fd7382b0"
LOCAL_ID = "714b0eae-b568-4e0c-a70b-c87c0d0a801a"
CATALOG_FIXTURE = {"schemaVersion": 1, "providers": {
    "claude": {"displayName": "Claude Code", "executable": "claude", "resume": ["{executable}", "--resume", "{sessionId}", "{arguments}"],
               "noPrompt": {"suffix": ["--dangerously-skip-permissions"], "rootEnvironment": {"IS_SANDBOX": "1"}}},
    "codex": {"displayName": "Codex", "executable": "codex", "resume": ["{executable}", "resume", "{sessionId}", "{arguments}"],
              "noPrompt": {"prefix": ["--yolo"], "legacy": ["--dangerously-bypass-approvals-and-sandbox"]}},
    "grok": {"displayName": "Grok", "executable": "grok", "resume": ["{executable}", "-r", "{sessionId}", "{arguments}"]}}}
RESPONSES = ("details-response-local.json", "details-response-ssh.json", "details-response-no-agent.json",
             "details-response-saved-shell.json", "details-response-sin-id.json", "details-response-interrupted.json",
             "details-response-no-tmux.json", "details-response-local-unreachable.json",
             "details-response-vault-closed.json")


def epoch(value):
    return calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ"))


def fixture_catalog():
    directory = tempfile.TemporaryDirectory(prefix="uc-details-catalog-")
    path = Path(directory.name) / "catalog.json"
    path.write_text(json.dumps(CATALOG_FIXTURE))
    try:
        return AgentResumeCatalog(path)
    finally:
        directory.cleanup()


def response(name):
    return json.loads(contract("window-details-v1", name).read_text(encoding="utf-8"))


def inputs_from(expected):
    """Ventana guardada, lectura viva y destino resuelto que deben producir exactamente ``expected``."""
    box = expected["workspace"]
    workspace = {"id": expected["workspace_id"], "name": box["name"], "kind": box["kind"]}
    endpoint = None
    if box["kind"] == "ssh":
        if box["host"]:
            endpoint = (box["host"]["user"], box["host"]["hostname"], str(box["host"]["port"]))
        else:
            workspace["hostLabel"] = box["host_label"]
    record = {"id": expected["terminal_id"], "name": expected["window"]["name"], "agent": "shell", "cwd": "/"}
    tmux, agent, reason = expected["tmux"], expected["agent"], expected["reason"]
    live = None
    if tmux:
        record.update(tmux=tmux["session"], tmuxSocket=tmux["socket"])
        if tmux["live"]:
            entry = {"name": tmux["session"], "session_id": tmux["session_id"], "pane_id": tmux["pane_id"], "live": True,
                     "reason": reason if reason in LIVE_REASONS else None, "agent": None}
            if agent and agent["state"] == "activo":
                entry["agent"] = {key: agent[key] for key in ("provider", "session_id", "cwd", "as_root", "source")}
            live = {"ok": True, "error": None, "checked_at": agent["observed_at"] if agent and agent["state"] == "activo"
                    else expected["checked_at"], "session": entry}
        elif reason == "host_inaccesible":
            live = {"ok": False, "error": "host_inaccesible", "checked_at": None, "session": None}
        else:
            live = {"ok": True, "error": None, "checked_at": expected["checked_at"], "session": None}
    if agent and agent["state"] != "activo":
        record.update(agent=agent["provider"], sessionId=agent["session_id"], resumeCwd=agent["cwd"],
                      interrupted=agent["state"] == "interrumpido", runtimeState="shell")
        if not (box["kind"] == "ssh" and box["host"] is None):
            record["asRoot"] = agent["as_root"]  # Con la bóveda cerrada, as_root sale de la etiqueta.
        if agent["observed_at"]:
            record["agentObservedAt"] = epoch(agent["observed_at"])
    return workspace, record, live, endpoint, lambda: epoch(expected["checked_at"])


class SnapshotContractTests(unittest.TestCase):
    """Las nueve respuestas de contracts/window-details-v1 y sus filas literales (filas.json)."""

    def test_every_contract_response(self):
        catalog = AgentResumeCatalog()
        for name in RESPONSES:
            with self.subTest(respuesta=name):
                expected = response(name)
                workspace, record, live, endpoint, clock = inputs_from(expected)
                self.assertEqual(WindowDetails.snapshot(workspace, record, live, catalog, clock, endpoint=endpoint), expected)

    def test_rows_warning_and_note_are_the_literal_texts(self):
        cases = json.loads(contract("window-details-v1", "filas.json").read_text(encoding="utf-8"))["casos"]
        self.assertEqual({case["fixture"] for case in cases}, set(RESPONSES))
        for case in cases:
            with self.subTest(respuesta=case["fixture"]):
                details = response(case["fixture"])
                self.assertEqual([[label, value] for _, label, value in WindowDetails.rows(details)], case["filas"])
                self.assertEqual(WindowDetails.warning(details), case["aviso"])
                self.assertEqual(WindowDetails.command_note(details), case["nota_orden"])


class SnapshotRuleTests(unittest.TestCase):
    def test_host_label_is_always_user_host_port(self):
        for value, expected in (("('ec2-user', 'host.example', '2222')", "ec2-user@host.example:2222"),
                                ("root@167.233.192.135", "root@167.233.192.135:22"), ("root@h:2222", "root@h:2222"),
                                ("root@[2001:db8::1]:2200", "root@[2001:db8::1]:2200"),
                                ("root@2001:db8::1", "root@[2001:db8::1]:22"), ("xunis", "xunis:22"),
                                ("(roto", "(roto"), (None, None), ("", None)):
            with self.subTest(value=value):
                self.assertEqual(WindowDetails.host_label(value), expected)
        self.assertEqual(WindowDetails.endpoint_label("root", "2001:db8::1", "22"), "root@[2001:db8::1]:22")

    def test_saved_agent_survives_a_shell_and_uses_history_when_the_active_one_has_no_id(self):
        catalog = fixture_catalog()
        workspace = {"id": "box", "name": "PROYECTOS", "kind": "local"}
        record = {"id": "w", "name": "codex", "tmux": "uc-w", "agent": "shell", "cwd": "/w", "runtimeState": "shell",
                  "history": [{"agent": "claude", "sessionId": LOCAL_ID, "cwd": "/w/a", "lastSeenAt": 10},
                              {"agent": "codex", "sessionId": "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17", "cwd": "/w/b",
                               "lastSeenAt": 20}]}
        live = {"ok": True, "checked_at": "2026-09-24T14:30:04Z",
                "session": {"name": "uc-w", "session_id": "$1", "pane_id": "%1", "reason": "panel_muerto", "agent": None}}
        details = WindowDetails.snapshot(workspace, record, live, catalog, lambda: 0)
        self.assertEqual((details["agent"]["provider"], details["agent"]["cwd"], details["agent"]["state"],
                          details["agent"]["as_root"], details["reason"]), ("codex", "/w/b", "guardado", False, "sin_ia"))
        # Una IA guardada sin id no cambia reason (sin_id solo sale de una IA en marcha).
        fresh = {"id": "f", "name": "claude", "tmux": "uc-f", "agent": "claude", "cwd": "/w"}
        details = WindowDetails.snapshot(workspace, fresh, {"ok": True, "checked_at": None, "session": None}, catalog, lambda: 0)
        self.assertEqual((details["agent"]["session_id"], details["agent"]["resume"], details["reason"]), (None, None, None))
        self.assertIn(["IA", "Claude Code: sin identificador guardado"], [[l, v] for _, l, v in WindowDetails.rows(details)])

    def test_live_ambiguity_missing_id_and_unverified_policy(self):
        catalog = fixture_catalog()
        workspace = {"id": "box", "name": "PROYECTOS", "kind": "local"}
        record = {"id": "w", "name": "grok", "tmux": "uc-w", "agent": "claude", "sessionId": LOCAL_ID, "cwd": "/w"}
        live = {"ok": True, "checked_at": "2026-09-24T14:30:04Z",
                "session": {"name": "uc-w", "session_id": "$1", "pane_id": "%1", "reason": "identidad_ambigua", "agent": None}}
        details = WindowDetails.snapshot(workspace, record, live, catalog, lambda: 0)
        self.assertEqual((details["reason"], details["agent"]["state"]), ("identidad_ambigua", "guardado"))
        self.assertIn(["IA", "Hay más de una IA en esta ventana"], [[l, v] for _, l, v in WindowDetails.rows(details)])
        live["session"].update(reason="sin_id", agent={"provider": "codex", "session_id": None, "cwd": "/w",
                                                      "as_root": False, "source": "argv"})
        details = WindowDetails.snapshot(workspace, record, live, catalog, lambda: 0)
        self.assertEqual((details["reason"], details["agent"]["resume"], details["agent"]["source"]), ("sin_id", None, None))
        live["session"].update(reason=None, agent={"provider": "grok", "session_id": "conv_1", "cwd": "/w",
                                                  "as_root": False, "source": "argv"})
        details = WindowDetails.snapshot(workspace, record, live, catalog, lambda: 0)
        self.assertEqual(details["agent"]["resume"], {"argv": ["grok", "-r", "conv_1"], "environment": {},
                                                      "command": "cd -- '/w' && grok -r conv_1", "no_prompt_verified": False})
        self.assertEqual(WindowDetails.command_note(details), "Sin modo sin preguntas verificado para esta IA")


class FakeConnection:
    def __init__(self, endpoint):
        self.endpoint, self.calls = endpoint, []

    def endpoint_key(self, *, resolve=True):
        self.calls.append(resolve)
        return self.endpoint


class GatherTests(unittest.TestCase):
    """La ruta común (modal, RPC y CLI): ssh -G y sonda fuera de GTK, nunca un error por la sonda."""

    def setUp(self):
        self.workspace = {"id": "box", "name": "XUNIS", "kind": "ssh", "hostLabel": "xunis-alias"}
        self.record = {"id": "w", "name": "claudebets", "tmux": "claudebets", "tmuxSocket": "default", "agent": "claude",
                       "sessionId": CLAUDE_ID, "resumeCwd": "/root/xunis", "runtimeState": "agent"}
        self.probes = []

    def probe(self, transport, socket_name, sessions, *, timeout):
        self.probes.append((transport, socket_name, list(sessions), timeout))
        if transport == "caida":
            raise TimeoutError("sonda vencida")
        return {"version": 1, "error": None, "checked_at": "2026-09-24T14:30:04Z", "sessions": [
            {"name": "claudebets", "session_id": "$0", "pane_id": "%0", "live": True, "reason": None,
             "agent": {"provider": "claude", "session_id": CLAUDE_ID, "cwd": "/root/xunis", "as_root": True, "source": "ficha"}}]}

    def gather(self, connection, transport):
        return WindowDetails.gather(self.workspace, self.record, connection=connection, transport=transport,
                                    catalog=fixture_catalog(), clock=lambda: 0, probe=self.probe)

    def test_host_is_the_resolved_destination_not_the_alias(self):
        connection = FakeConnection(("root", "167.233.192.135", "22"))
        details = self.gather(connection, "transporte")
        self.assertEqual(connection.calls, [True])  # Resuelto con ssh -G.
        self.assertEqual(details["workspace"]["host"], {"user": "root", "hostname": "167.233.192.135", "port": 22})
        self.assertEqual(details["workspace"]["host_label"], "root@167.233.192.135:22")
        self.assertEqual((details["agent"]["state"], details["reason"]), ("activo", None))
        self.assertEqual(self.probes, [("transporte", "default", ["claudebets"], 8)])

    def test_locked_vault_or_failed_probe_answer_with_the_saved_values(self):
        closed = self.gather(None, None)
        self.assertEqual((closed["workspace"]["host"], closed["workspace"]["host_label"]), (None, "xunis-alias:22"))
        self.assertEqual((closed["reason"], closed["agent"]["state"], closed["agent"]["source"]),
                         ("host_inaccesible", "guardado", "registro"))
        self.assertEqual(self.probes, [])
        self.workspace["hostLabel"] = "root@167.233.192.135:22"
        closed = self.gather(None, None)
        self.assertTrue(closed["agent"]["as_root"])  # Por el usuario de la etiqueta.
        self.assertIn("IS_SANDBOX=1", closed["agent"]["resume"]["command"])
        failed = self.gather(FakeConnection(("dani", "10.0.0.2", "2222")), "caida")
        self.assertEqual((failed["reason"], failed["tmux"]["live"], failed["agent"]["as_root"]),
                         ("host_inaccesible", False, False))
        self.assertEqual(WindowDetails.warning(failed), "No se pudo comprobar el servidor; se muestra lo guardado")
        local = WindowDetails.gather({"id": "l", "name": "L", "kind": "local"}, dict(self.record, tmuxSocket="uniconnect-local"),
                                     connection=None, transport="caida", catalog=fixture_catalog(), clock=lambda: 0,
                                     probe=self.probe)
        self.assertEqual(WindowDetails.warning(local), "No se pudo comprobar tmux en este equipo; se muestra lo guardado")

    def test_window_without_tmux_is_not_probed(self):
        legacy = WindowDetails.gather({"id": "l", "name": "L", "kind": "local"}, {"id": "p", "name": "pty", "cwd": "/"},
                                      connection=None, transport=None, catalog=fixture_catalog(), clock=lambda: 0,
                                      probe=self.probe)
        self.assertEqual((legacy["tmux"], legacy["agent"], legacy["reason"]), (None, None, "sin_tmux"))
        self.assertEqual(self.probes, [])


try:
    from test_new_conversation import GTK_AVAILABLE
    if GTK_AVAILABLE:
        from test_new_conversation import ConversationDesktop
        from uniconnect.terminal import TerminalSurface
        from uniconnect.window import MainWindow
except Exception:
    GTK_AVAILABLE = False


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required for the three context menus")
class DetailsMenuTests(unittest.TestCase):
    def test_terminal_tab_and_sidebar_menus_offer_details_and_run_the_shared_action(self):
        class DetailsDesktop(ConversationDesktop):
            sidebar_surface_context = MainWindow.sidebar_surface_context

            def select_sidebar_surface(self, workspace_id, surface_id):
                return True

            def show_window_details(self, surface):
                self.shown = surface

        desktop = DetailsDesktop()
        desktop.tab_context(None, SimpleNamespace(button=3), desktop.focused_surface)
        desktop.sidebar_surface_context("box", "original-window", SimpleNamespace(button=3), None)
        TerminalSurface.on_button(SimpleNamespace(on_focus=lambda: None, owner=desktop), None, SimpleNamespace(button=3))
        self.assertEqual(len(desktop.contexts), 3)
        for names in desktop.contexts:
            self.assertIn("window_details", names)
        self.assertTrue(desktop.action_enabled("window_details"))
        desktop.run_action("window_details")
        self.assertIs(desktop.shown, desktop.focused_surface)
        self.assertEqual(desktop.action_label("window_details"), "Detalles…")


if __name__ == "__main__":
    unittest.main()
