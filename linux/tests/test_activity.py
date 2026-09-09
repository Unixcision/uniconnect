"""activity.v1 en el host Linux: reglas por ventana, agregado por caja, sonda tmux y kind de los avisos."""

import base64
import types
import unittest

from test_mobile_pty import SocketProcess
from uniconnect.activity import (ActivityResolver, AgentActivity, activity_snapshot, aggregate_state,
                                 agent_from_command, kind_from_hook, notification_kind, parse_list_panes,
                                 permission_visible, probe_script, select_pane, split_notify_payload,
                                 workspace_activity)
from uniconnect.activity_monitor import ActivityMonitor
from uniconnect.mobile_protocol import RPCError
from uniconnect.mobile_pty import MobilePTYAttachments
from uniconnect.mobile_rpc import MobileRPC, notification_record


class ResolverRuleTests(unittest.TestCase):
    def setUp(self):
        self.now = 1_000_000.0
        self.resolver = ActivityResolver(clock=lambda: self.now)
        self.screens = []

    def screen(self, lines):
        def read():
            self.screens.append(True)
            return lines
        return read

    def running(self, command="claude", title="", *, output_ago=None):
        self.resolver.note_alive("w", True, launched="claude")
        self.resolver.note_probe("w", command, title)
        if output_ago is not None:
            self.resolver.note_output("w", self.now - output_ago)

    def test_shell_is_unknown_whatever_the_title_or_output_says(self):
        self.running("bash", "⠋ codex trabajando", output_ago=0.5)
        activity = self.resolver.evaluate("w")
        self.assertEqual((activity.state, activity.agent), ("unknown", None))
        self.running("/usr/bin/zsh", "✳ tema", output_ago=0.1)
        self.assertEqual(self.resolver.evaluate("w").state, "unknown")

    def test_agent_comes_from_the_foreground_command_first(self):
        self.assertEqual(agent_from_command("/usr/local/bin/claude"), ("claude", False, True))
        self.assertEqual(agent_from_command("codex"), ("codex", False, True))
        self.assertEqual(agent_from_command("gemini"), ("gemini", False, True))
        self.assertEqual(agent_from_command("agy"), ("agy", False, True))
        self.assertEqual(agent_from_command("node"), (None, False, True))
        self.assertEqual(agent_from_command("fish"), (None, True, False))
        self.assertEqual(agent_from_command(None), (None, False, False))
        self.running("node", "✳ tema", output_ago=10)
        activity = self.resolver.evaluate("w")
        self.assertEqual((activity.state, activity.agent), ("idle", "claude"))  # node vivo; ✳ solo nombra.

    def test_fresh_hooks_win_and_stale_hooks_are_ignored(self):
        self.running("claude", output_ago=0.2)
        self.resolver.note_hook("w", "needsInput", "claude")
        activity = self.resolver.evaluate("w")
        self.assertEqual((activity.state, activity.source), ("waiting", "hooks"))
        self.now += 119
        self.assertEqual(self.resolver.evaluate("w").state, "waiting")
        self.now += 2
        self.resolver.note_output("w")
        self.assertEqual(self.resolver.evaluate("w"), self.resolver.evaluate("w"))
        self.assertEqual((self.resolver.current("w").state, self.resolver.current("w").source), ("working", "output"))
        self.resolver.note_hook("w", "running")
        self.assertEqual(self.resolver.evaluate("w").source, "hooks")
        self.resolver.note_hook("w", "idle")
        self.assertEqual(self.resolver.evaluate("w").state, "idle")
        self.resolver.note_hook("w", "explotó")  # Un estado desconocido no cambia nada.
        self.assertEqual(self.resolver.evaluate("w").state, "idle")

    def test_permission_question_on_screen_beats_title_and_is_read_only_when_quiet(self):
        prompt = ["\x1b[1mBash command\x1b[0m", "rm -rf build", "Do you want to proceed?", "❯ 1. Yes", "  2. No", "Esc to cancel"]
        self.running("codex", "⠙ working", output_ago=0.4)
        activity = self.resolver.evaluate("w", screen=self.screen(prompt))
        self.assertEqual((activity.state, activity.source), ("working", "title"))
        self.assertEqual(self.screens, [])  # Con salida hace 0.4 s la pantalla no se mira.
        self.now += 1
        activity = self.resolver.evaluate("w", screen=self.screen(prompt))
        self.assertEqual((activity.state, activity.source, activity.agent), ("waiting", "screen", "codex"))
        self.assertEqual(len(self.screens), 1)
        self.now += 2
        self.assertEqual(self.resolver.evaluate("w", screen=self.screen(prompt)).state, "waiting")
        self.assertEqual(len(self.screens), 1)  # Sin salida nueva, el veredicto se conserva sin releer.
        self.now += 10
        self.assertEqual(self.resolver.evaluate("w", screen=self.screen(prompt)).state, "waiting")
        self.resolver.note_output("w")
        self.now += 1.5
        activity = self.resolver.evaluate("w", screen=self.screen(["$ listo", "todo bien"]))
        self.assertEqual(len(self.screens), 2)
        self.assertEqual((activity.state, activity.source), ("working", "title"))

    def test_permission_patterns_cover_the_three_families(self):
        self.assertTrue(permission_visible(["Allow this command? [y/n]"]))
        self.assertTrue(permission_visible(["Would you like to run `npm test`?"]))
        self.assertTrue(permission_visible(["Allow execution of shell command?"]))
        self.assertTrue(permission_visible(["Apply this change?"]))
        self.assertFalse(permission_visible(["compilando...", "ok"]))
        self.assertFalse(permission_visible(["Do you want to proceed?"] + ["línea"] * 12))  # Fuera de las últimas 12.

    def test_braille_title_means_working_and_asterisk_means_nothing(self):
        self.running("codex", "⠹ Codex", output_ago=30)
        activity = self.resolver.evaluate("w")
        self.assertEqual((activity.state, activity.source, activity.agent), ("working", "title", "codex"))
        self.running("claude", "✳ Refactor del router", output_ago=30)
        activity = self.resolver.evaluate("w")
        self.assertEqual((activity.state, activity.source, activity.agent), ("idle", "output", "claude"))
        self.resolver.note_probe("w", None, "✳ Refactor del router")  # Sin comando, el título solo nombra.
        activity = self.resolver.evaluate("w")
        self.assertEqual((activity.state, activity.agent), ("idle", "claude"))

    def test_output_thresholds_three_and_five_seconds(self):
        self.running("claude", output_ago=1)
        self.assertEqual(self.resolver.evaluate("w").state, "working")
        self.now += 3  # 4 s: se conserva el estado anterior.
        self.assertEqual(self.resolver.evaluate("w").state, "working")
        self.now += 2  # 6 s: idle con agente vivo.
        activity = self.resolver.evaluate("w")
        self.assertEqual((activity.state, activity.source), ("idle", "output"))
        self.now += 60
        self.assertEqual(self.resolver.evaluate("w").state, "idle")
        self.resolver.note_alive("w", False)  # El proceso murió: ya no es idle.
        self.assertEqual(self.resolver.evaluate("w").state, "unknown")
        self.resolver.note_alive("w", True)
        self.resolver.note_output("w")
        self.assertEqual(self.resolver.evaluate("w").state, "working")

    def test_keyboard_echo_and_resize_redraws_do_not_count_as_output(self):
        self.running("claude", output_ago=30)
        self.assertEqual(self.resolver.evaluate("w").state, "idle")
        self.resolver.note_input("w")
        self.now += 0.1
        self.assertFalse(self.resolver.note_output("w"))
        self.assertEqual(self.resolver.evaluate("w").state, "idle")
        self.now += 0.3  # Pasados 250 ms del teclado, la salida vuelve a contar.
        self.assertTrue(self.resolver.note_output("w"))
        self.assertEqual(self.resolver.evaluate("w").state, "working")
        self.now += 10
        self.assertEqual(self.resolver.evaluate("w").state, "idle")
        self.resolver.note_resize("w")
        self.now += 0.4
        self.assertFalse(self.resolver.note_output("w"))
        self.assertEqual(self.resolver.evaluate("w").state, "idle")
        self.now += 0.2
        self.assertTrue(self.resolver.note_output("w"))

    def test_since_changes_only_with_the_state(self):
        self.running("claude", output_ago=0.5)
        first = self.resolver.evaluate("w")
        self.assertEqual(first.since, self.now)
        self.now += 1
        self.resolver.note_output("w")
        self.assertEqual(self.resolver.evaluate("w").since, first.since)
        self.now += 10
        idle = self.resolver.evaluate("w")
        self.assertEqual((idle.state, idle.since), ("idle", self.now))
        self.assertEqual(idle.snapshot(), {"state": "idle", "source": "output", "agent": "claude", "since": int(self.now)})
        self.assertEqual(AgentActivity().snapshot(), {"state": "unknown", "source": "output", "agent": None, "since": 0})

    def test_tmux_window_activity_is_only_a_fallback_without_pty_data(self):
        self.resolver.note_alive("w", True)
        self.resolver.note_probe("w", "claude", "", window_activity=self.now - 1)
        self.assertEqual(self.resolver.evaluate("w").state, "working")
        self.resolver.note_output("w", self.now - 20)
        self.resolver.note_probe("w", "claude", "", window_activity=self.now)
        self.assertEqual(self.resolver.evaluate("w").state, "idle")
        self.resolver.forget("w")
        self.assertEqual(self.resolver.current("w"), AgentActivity())

    def test_first_screen_read_happens_without_any_observed_output(self):
        prompt = ["Would you like to run `make`?", "[y/n]"]
        self.resolver.note_alive("w", True)
        self.resolver.note_probe("w", "codex", "", window_activity=self.now - 30)  # Solo la marca de tmux.
        activity = self.resolver.evaluate("w", screen=self.screen(prompt))
        self.assertEqual((activity.state, activity.source), ("waiting", "screen"))
        self.assertEqual(len(self.screens), 1)
        self.resolver.note_probe("w", "codex", "")
        self.resolver.forget("w")
        self.resolver.note_alive("w", True)
        self.resolver.note_probe("w", "codex", "")  # Sin salida ni marca: quieto "desde siempre".
        self.assertEqual(self.resolver.evaluate("w", screen=self.screen(prompt)).state, "waiting")
        self.assertEqual(len(self.screens), 2)

    def test_discarded_echo_and_resize_still_invalidate_the_screen_verdict(self):
        prompt = ["Do you want to proceed?", "❯ 1. Yes"]
        self.running("claude", output_ago=30)
        self.assertEqual(self.resolver.evaluate("w", screen=self.screen(prompt)).state, "waiting")
        self.resolver.note_input("w")
        self.now += 0.1
        self.assertFalse(self.resolver.note_output("w"))  # Eco del "1" del usuario: cambió la pantalla.
        self.now += 2
        activity = self.resolver.evaluate("w", screen=self.screen(["$ trabajando", "ok"]))
        self.assertEqual(len(self.screens), 2)
        self.assertEqual(activity.state, "idle")  # Sin la pregunta y sin salida contada: idle.
        self.resolver.note_resize("w")
        self.now += 2
        self.resolver.evaluate("w", screen=self.screen(prompt))
        self.assertEqual(len(self.screens), 3)
        self.assertEqual(self.resolver.current("w").state, "waiting")

    def test_dead_process_is_unknown_even_from_working_title_or_waiting_screen(self):
        self.running("codex", "⠹ Codex", output_ago=30)
        self.assertEqual(self.resolver.evaluate("w").state, "working")
        self.resolver.note_alive("w", False)  # Codex murió con el spinner aún en el título.
        activity = self.resolver.evaluate("w")
        self.assertEqual((activity.state, activity.agent), ("unknown", None))
        self.running("claude", output_ago=30)
        prompt = ["Do you want to proceed?", "❯ 1. Yes"]
        self.assertEqual(self.resolver.evaluate("w", screen=self.screen(prompt)).state, "waiting")
        self.resolver.note_alive("w", False)
        self.assertEqual(self.resolver.evaluate("w", screen=self.screen(prompt)).state, "unknown")
        self.resolver.note_alive("w", True)
        self.resolver.clear_probe("w")  # La sonda ya no encuentra la sesión: ni título ni comando.
        self.assertEqual(self.resolver.evaluate("w").state, "unknown")
        self.resolver.note_probe("w", "codex", "⠹ Codex")
        self.assertEqual(self.resolver.evaluate("w").state, "working")


class AggregateAndProbeTests(unittest.TestCase):
    def test_workspace_priority(self):
        self.assertEqual(aggregate_state(["idle", "working", "unknown"]), "working")
        self.assertEqual(aggregate_state(["working", "waiting"]), "waiting")
        self.assertEqual(aggregate_state(["unknown", "idle"]), "idle")
        self.assertEqual(aggregate_state([]), "unknown")

    def test_probe_script_and_parsing(self):
        script = probe_script("uniconnect-local")
        self.assertTrue(script.startswith("tmux -L uniconnect-local list-panes -a -F "))
        self.assertIn("#{session_name}", script)
        self.assertIn("#{pane_current_command}", script)
        self.assertIn("#{pane_title}", script)
        self.assertIn("#{window_activity}", script)
        self.assertIn("#{pane_id}", script)
        output = ("uc-a-1\t%0\tclaude\t✳ tema\t1700000000\n"
                  "uc-b-2\t%3\tbash\tbash\t1700000100\n"
                  "uc-b-2\t%4\tcodex\t⠋ codex\t1700000200\n"
                  "rota\n"
                  "uc-x\tsinpane\tclaude\tt\t1\n"
                  "uc-c-3\t%9\tnode\t\tnada\n")
        parsed = parse_list_panes(output)
        self.assertEqual(parsed["uc-a-1"], {"%0": ("claude", "✳ tema", 1700000000.0)})
        self.assertEqual(parsed["uc-b-2"], {"%3": ("bash", "bash", 1700000100.0), "%4": ("codex", "⠋ codex", 1700000200.0)})
        self.assertEqual(parsed["uc-c-3"], {"%9": ("node", "", None)})
        self.assertNotIn("uc-x", parsed)
        self.assertEqual(parse_list_panes(""), {})

    def test_saved_pane_identity_decides_and_ambiguity_never_picks_one(self):
        panes = {"%3": ("bash", "bash", 1.0), "%4": ("codex", "⠋ codex", 2.0)}
        self.assertEqual(select_pane(panes, "%3"), ("bash", "bash", 1.0))
        self.assertEqual(select_pane(panes, "%4"), ("codex", "⠋ codex", 2.0))
        self.assertIsNone(select_pane(panes, "%7"))
        self.assertIsNone(select_pane(panes, None))  # Dos panes sin paneId guardado: ambiguo.
        self.assertIsNone(select_pane(panes, "main"))
        self.assertEqual(select_pane({"%0": ("claude", "", None)}, None), ("claude", "", None))
        self.assertEqual(select_pane({"%0": ("claude", "", None)}, "main"), ("claude", "", None))
        self.assertIsNone(select_pane({}, "%0"))
        self.assertIsNone(select_pane(None, "%0"))


class NotificationKindTests(unittest.TestCase):
    def test_hook_events_map_to_attention_finished_or_info(self):
        for event in ("permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
                      "PermissionRequest", "needsInput"):
            self.assertEqual(kind_from_hook(event), "attention", event)
        for event in ("idle_prompt", "agent_completed", "Stop", "stop", "idle", "agent-turn-complete"):
            self.assertEqual(kind_from_hook(event), "finished", event)
        self.assertEqual(kind_from_hook("error"), "info")
        self.assertEqual(kind_from_hook("Notification"), "info")
        self.assertIsNone(kind_from_hook(None))

    def test_without_hook_kind_the_window_activity_decides(self):
        self.assertEqual(notification_kind(None, "waiting"), "attention")
        self.assertEqual(notification_kind(None, "idle"), "finished")
        self.assertEqual(notification_kind(None, "working"), "info")
        self.assertEqual(notification_kind(None, "unknown"), "info")
        self.assertEqual(notification_kind("finished", "waiting"), "finished")
        self.assertEqual(notification_kind("bogus", "waiting"), "attention")

    def test_notify_payload_fourth_field_is_kind_only_when_valid(self):
        self.assertEqual(split_notify_payload("Claude|Caja|Necesita permiso|attention"),
                         ("Claude", "Caja", "Necesita permiso", "attention"))
        self.assertEqual(split_notify_payload("Claude|Caja|a|b|c"), ("Claude", "Caja", "a|b|c", None))
        self.assertEqual(split_notify_payload("Solo título"), ("Solo título", "", "", None))

    def test_notification_record_persists_kind_with_info_default(self):
        workspace, record = {"id": "ws", "name": "Caja"}, {"id": "win", "name": "Ventana"}
        self.assertEqual(notification_record(workspace, record, 1.5, "n1")["kind"], "info")
        self.assertEqual(notification_record(workspace, record, 1.5, "n1", kind="attention")["kind"], "attention")
        self.assertEqual(notification_record(workspace, record, 1.5, "n1", kind="raro")["kind"], "info")


class FakeTerminal:
    def __init__(self):
        self.columns, self.rows = 80, 24

    def get_column_count(self):
        return self.columns

    def get_row_count(self):
        return self.rows

    def set_size(self, columns, rows):
        self.columns, self.rows = columns, rows


class FakeMonitor:
    def __init__(self):
        self.states = {}
        self.inputs, self.resizes = [], []

    def activity(self, window_id):
        return self.states.get(window_id, AgentActivity())

    def note_input(self, window_id):
        self.inputs.append(window_id)

    def note_resize(self, window_id):
        self.resizes.append(window_id)


class RPCTests(unittest.TestCase):
    def setUp(self):
        self.records = [{"id": "a", "name": "Claude", "tmux": "uc-a", "cwd": "/tmp", "agent": "claude"},
                        {"id": "b", "name": "Shell", "tmux": "uc-b", "cwd": "/tmp"}]
        self.workspace = {"id": "ws", "name": "Caja", "kind": "local", "cwd": "/tmp", "windows": self.records}
        self.sent = []
        self.surface = types.SimpleNamespace(record=self.records[0], pid=7, disposed=False, terminal=FakeTerminal(),
                                             send=self.sent.append)
        self.monitor = FakeMonitor()
        self.window = types.SimpleNamespace(
            store=types.SimpleNamespace(workspaces=[self.workspace], data={"notificationHistory": [
                {"id": "old", "workspace_id": "ws", "surface_id": "a", "title": "t", "created_at_ms": 5, "is_read": False},
                {"id": "new", "workspace_id": "ws", "surface_id": "a", "title": "t", "created_at_ms": 6, "is_read": False,
                 "kind": "attention"}]}),
            locked=False, surfaces={"a": self.surface}, focused_surface=None, activity=self.monitor)
        self.rpc = MobileRPC(self.window, None, lambda callback: callback())

    def test_workspace_list_publishes_activity_per_terminal_and_workspace(self):
        self.monitor.states["a"] = AgentActivity("waiting", "screen", "claude", 1700000000.4)
        result = self.rpc.dispatch("mobile.workspace.list", {}, "peer")
        self.assertEqual(result["capabilities"], ["activity.v1", "box_update", "file_put.v1", "transcribe.v1"])
        box = result["workspaces"][0]
        self.assertEqual(box["activity"], {"state": "waiting"})
        self.assertEqual(box["terminals"][0]["activity"],
                         {"state": "waiting", "source": "screen", "agent": "claude", "since": 1700000000})
        self.assertEqual(box["terminals"][1]["activity"],
                         {"state": "unknown", "source": "output", "agent": None, "since": 0})
        self.monitor.states["a"] = AgentActivity("idle", "output", "claude", 10)
        self.assertEqual(self.rpc.dispatch("mobile.workspace.list", {}, "peer")["workspaces"][0]["activity"], {"state": "idle"})

    def test_hosts_without_monitor_answer_unknown(self):
        del self.window.activity
        self.assertEqual(activity_snapshot(None, "a")["state"], "unknown")
        self.assertEqual(workspace_activity(None, self.workspace), {"state": "unknown"})
        box = self.rpc.dispatch("mobile.workspace.list", {}, "peer")["workspaces"][0]
        self.assertEqual(box["activity"], {"state": "unknown"})
        self.assertEqual(box["terminals"][0]["activity"]["state"], "unknown")

    def test_notifications_list_carries_kind_with_info_for_old_records(self):
        items = self.rpc.dispatch("mobile.notifications.list", {}, "peer")["notifications"]
        self.assertEqual([(item["id"], item["kind"]) for item in items], [("new", "attention"), ("old", "info")])
        self.assertNotIn("kind", self.window.store.data["notificationHistory"][0])  # Se lee como info, no se reescribe.

    def test_mobile_typing_and_resizes_are_reported_as_non_output(self):
        params = {"workspace_id": "ws", "surface_id": "a"}
        self.rpc.dispatch("mobile.terminal.input", {**params, "text": "ls\n"}, "peer")
        self.assertEqual((self.monitor.inputs, self.sent), (["a"], ["ls\n"]))
        self.rpc.dispatch("mobile.terminal.viewport", {**params, "client_id": "m", "viewport_columns": 60, "viewport_rows": 20}, "peer")
        self.assertEqual(self.monitor.resizes, ["a"])
        with self.assertRaises(RPCError):
            self.rpc.dispatch("mobile.terminal.input", {**params, "text": 7}, "peer")
        self.window.locked = True
        with self.assertRaises(RPCError):
            self.rpc.dispatch("mobile.terminal.input", {**params, "text": "x"}, "peer")
        self.window.locked = False
        self.assertEqual((self.monitor.inputs, self.monitor.resizes), (["a"], ["a"]))  # Rechazados: sin efecto.

    def test_pty_activity_is_serialized_through_the_model_owner(self):
        scheduled = []
        rpc = MobileRPC(self.window, None, scheduled.append)
        rpc.pty_activity("a", "input")
        rpc.pty_activity("a", "resize")
        self.assertEqual((self.monitor.inputs, self.monitor.resizes), ([], []))  # Nada hasta el hilo dueño.
        self.assertEqual([callback() for callback in scheduled], [False, False])
        self.assertEqual((self.monitor.inputs, self.monitor.resizes), (["a"], ["a"]))
        del self.window.activity
        rpc.pty_activity("a", "input")
        scheduled[-1]()  # Sin monitor no hay nada que anotar ni que falle.
        rpc.close_attachments()


class PTYBoundaryTests(unittest.TestCase):
    """El teclado/tamaño del PTY móvil solo llega al monitor por el camino ya validado."""

    def setUp(self):
        self.approved = {"owner": True, "other": True}
        self.notes = []
        self.processes = []
        def factory(launch, columns, rows):
            process = SocketProcess()
            self.processes.append(process)
            return process
        self.manager = MobilePTYAttachments(
            prepare=lambda params, authorized: ("launch", {"workspace_id": "ws", "surface_id": params["surface_id"], "identity": 1}),
            validate=lambda target, authorized: None, has_topic=lambda connection, topic: True,
            emit=lambda connection, topic, payload: True, process_factory=factory,
            on_input=lambda surface_id, kind: self.notes.append((surface_id, kind)))

    def tearDown(self):
        self.manager.close()
        for process in self.processes:
            process.close()

    def dispatch(self, operation, params, connection="owner"):
        return self.manager.dispatch(operation, params, connection, lambda: self.approved[connection])

    def test_only_validated_input_and_resize_reach_the_activity_callback(self):
        attached = self.dispatch("terminal.attach", {"surface_id": "a", "client_id": "m", "columns": 80, "rows": 24})
        attach_id = attached["attach_id"]
        self.assertEqual(self.notes, [])
        data = base64.b64encode(b"ls\n").decode()
        rejected = [
            ("terminal.pty_input", {"attach_id": attach_id, "data": "!!!"}, "owner", "invalid_params"),
            ("terminal.pty_input", {"attach_id": attach_id, "data": ""}, "owner", "invalid_params"),
            ("terminal.pty_input", {"attach_id": "nope", "data": data}, "owner", "not_found"),
            ("terminal.pty_input", {"attach_id": attach_id, "data": data}, "other", "not_found"),
            ("terminal.pty_resize", {"attach_id": attach_id, "columns": 0, "rows": 5}, "owner", "invalid_params"),
            ("terminal.pty_resize", {"attach_id": attach_id, "columns": 10, "rows": 5}, "other", "not_found"),
        ]
        for operation, params, connection, code in rejected:
            with self.subTest(operation=operation, code=code), self.assertRaises(RPCError) as error:
                self.dispatch(operation, params, connection)
            self.assertEqual(error.exception.code, code)
        self.approved["owner"] = False
        with self.assertRaises(RPCError) as error:
            self.dispatch("terminal.pty_input", {"attach_id": attach_id, "data": data})
        self.assertEqual(error.exception.code, "approval_required")
        self.approved["owner"] = True
        self.assertEqual(self.notes, [])
        self.dispatch("terminal.pty_input", {"attach_id": attach_id, "data": data})
        self.dispatch("terminal.pty_resize", {"attach_id": attach_id, "columns": 100, "rows": 30})
        self.assertEqual(self.notes, [("a", "input"), ("a", "resize")])
        self.dispatch("terminal.detach", {"attach_id": attach_id})
        with self.assertRaises(RPCError):
            self.dispatch("terminal.pty_input", {"attach_id": attach_id, "data": data})
        self.assertEqual(self.notes, [("a", "input"), ("a", "resize")])


class FakeSurface:
    def __init__(self, record, workspace, pid=5, screen=None, title=""):
        self.record, self.workspace, self.pid, self.disposed = record, workspace, pid, False
        self.screen_reads = 0
        self._screen, self._title = screen or [], title
        self.terminal = types.SimpleNamespace(get_text_format=self.get_text_format,
                                              get_window_title=lambda: self._title, get_pty=lambda: None)

    def get_text_format(self, text_format):
        self.screen_reads += 1
        return "\n".join(self._screen)


class FakeWindow:
    def __init__(self, surfaces, *, kind_ssh=()):
        self._closed, self.locked = False, False
        self.surfaces = {surface.record["id"]: surface for surface in surfaces}
        self.vault = types.SimpleNamespace(locked=False)
        self.refreshes, self.connections, self.pending_work = 0, [], []

    def refresh_sidebar(self):
        self.refreshes += 1

    def connection(self, workspace):
        self.connections.append(workspace["id"])
        return "ssh dani@" + workspace["id"] + ".example.com"

    def background(self, work, done):
        self.pending_work.append((work, done))

    def run_pending(self):
        pending, self.pending_work = self.pending_work, []
        for work, done in pending:
            done(work())


class FakeTransport:
    outputs = {}
    runs = []

    def __init__(self, command, *, socket_name):
        self.command, self.socket_name = command, socket_name

    def run(self, script, **options):
        FakeTransport.runs.append((self.command.split()[-1] if self.command else None, self.socket_name))
        output = FakeTransport.outputs.get(self.socket_name)
        if output is None:
            raise RuntimeError("sin servidor")
        return types.SimpleNamespace(stdout=output)


class MonitorCompositionTests(unittest.TestCase):
    def setUp(self):
        FakeTransport.outputs, FakeTransport.runs = {}, []
        self.now, self.mono = 2_000_000.0, 100.0
        self.local = {"id": "local", "kind": "local", "windows": []}
        self.ssh = {"id": "srv", "kind": "ssh", "credentialId": "c", "windows": []}
        self.timers = []

    def monitor(self, *surfaces):
        window = FakeWindow(surfaces)
        monitor = ActivityMonitor(window, transport=FakeTransport, clock=lambda: self.now, monotonic=lambda: self.mono,
                                  timer=lambda ms, callback: self.timers.append((ms, callback)) or 1, cancel=lambda s: None)
        return window, monitor

    def record(self, workspace, identifier, **extra):
        record = {"id": identifier, "name": identifier, "tmux": "uc-" + identifier, **extra}
        workspace["windows"].append(record)
        return record

    def test_two_panes_of_one_session_are_attributed_by_pane_id_or_left_unknown(self):
        a = FakeSurface(self.record(self.local, "a", paneId="%1"), self.local)
        b = FakeSurface(self.record(self.local, "b", paneId="%2"), self.local)
        c = FakeSurface(self.record(self.local, "c"), self.local)  # Sin paneId guardado.
        for record in (a.record, b.record, c.record):
            record["tmux"] = "uc-shared"
        window, monitor = self.monitor(a, b, c)
        FakeTransport.outputs["uniconnect-local"] = ("uc-shared\t%1\tcodex\t⠋ codex\t1\n"
                                                     "uc-shared\t%2\tbash\tbash\t2\n")
        monitor.cycle()
        window.run_pending()
        self.assertEqual(FakeTransport.runs, [(None, "uniconnect-local")])  # Una sonda para las tres ventanas.
        self.assertEqual(monitor.activity("a").state, "working")
        self.assertEqual(monitor.activity("b").state, "unknown")
        self.assertEqual(monitor.activity("c").state, "unknown")  # Dos panes y ninguno guardado: ambiguo.
        self.assertEqual(window.refreshes, 1)

    def test_two_ssh_sockets_in_one_box_are_both_probed_without_overlap(self):
        a = FakeSurface(self.record(self.ssh, "a", tmuxSocket="uniconnect", paneId="%0"), self.ssh)
        b = FakeSurface(self.record(self.ssh, "b", tmuxSocket="otro", paneId="%0"), self.ssh)
        window, monitor = self.monitor(a, b)
        FakeTransport.outputs["uniconnect"] = "uc-a\t%0\tclaude\t✳ tema\t1\n"
        FakeTransport.outputs["otro"] = "uc-b\t%0\tcodex\t⠋ codex\t1\n"
        monitor.cycle()
        self.assertEqual(sorted(monitor.pending), [("srv", "otro"), ("srv", "uniconnect")])
        monitor.cycle()  # En vuelo: no se solapa.
        self.assertEqual(len(window.pending_work), 2)
        window.run_pending()
        self.assertEqual(sorted(FakeTransport.runs), [("dani@srv.example.com", "otro"), ("dani@srv.example.com", "uniconnect")])
        self.assertEqual(monitor.pending, set())
        self.assertEqual((monitor.activity("a").agent, monitor.activity("b").state), ("claude", "working"))
        self.mono += 5
        monitor.cycle()
        window.run_pending()
        self.assertEqual(len(FakeTransport.runs), 2)  # Antes de los 10 s ninguno se repite.
        self.mono += 6
        monitor.cycle()
        window.run_pending()
        self.assertEqual(len(FakeTransport.runs), 4)  # Los dos sockets vuelven a sondearse.
        window.vault.locked = True
        self.mono += 20
        monitor.cycle()
        window.run_pending()
        self.assertEqual(len(FakeTransport.runs), 4)  # Con la bóveda cerrada no se toca el remoto.

    def test_dead_window_and_failed_probe_forget_the_facts(self):
        a = FakeSurface(self.record(self.local, "a", paneId="%0"), self.local, screen=["Do you want to proceed?", "❯ 1. Yes"])
        window, monitor = self.monitor(a)
        FakeTransport.outputs["uniconnect-local"] = "uc-a\t%0\tcodex\t⠹ codex\t1\n"
        monitor.cycle()
        self.assertEqual(window.refreshes, 1)  # La pantalla ya decide waiting antes de saber el agente.
        window.run_pending()
        self.assertEqual((monitor.activity("a").state, monitor.activity("a").agent), ("waiting", "codex"))
        self.assertEqual((a.screen_reads, window.refreshes), (1, 2))
        a.pid = 0  # Codex murió con la pregunta aún en pantalla y el spinner en el título.
        monitor.cycle()
        self.assertEqual(monitor.activity("a").state, "unknown")
        self.assertEqual(a.screen_reads, 1)  # Muerta: no se lee la pantalla.
        self.assertEqual(window.refreshes, 3)
        a.pid = 9
        FakeTransport.outputs.pop("uniconnect-local")  # La sonda falla.
        monitor.cycle()
        window.run_pending()
        self.assertEqual(monitor.activity("a").state, "unknown")
        FakeTransport.outputs["uniconnect-local"] = "uc-otra\t%0\tcodex\t⠹ codex\t1\n"  # La sesión ya no está.
        monitor.cycle()
        window.run_pending()
        self.assertEqual(monitor.activity("a").state, "unknown")
        window.refreshes = 0
        monitor.cycle()
        self.assertEqual(window.refreshes, 0)  # Sin cambio no se refresca.
        a.disposed = True
        monitor.cycle()
        self.assertEqual(monitor.resolver.facts, {})
        window._closed = True
        self.assertFalse(monitor.cycle())


if __name__ == "__main__":
    unittest.main()
