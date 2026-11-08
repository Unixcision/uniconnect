"""box-close.v1 en Linux: cerrar una ventana o una caja desde el móvil, por el mismo camino del escritorio."""

import json
import types
import unittest

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False

from contracts_dir import contract
from uniconnect.mobile_protocol import RPCError
from uniconnect.mobile_rpc import MobileRPC
from uniconnect.state import StateError

if GTK_AVAILABLE:
    from uniconnect.window import MainWindow


class Capture:
    def __init__(self):
        self.lines = []

    def info(self, area, event, **fields):
        self.lines.append(("info", event, fields))

    def warn(self, area, event, **fields):
        self.lines.append(("warn", event, fields))


@unittest.skipUnless(GTK_AVAILABLE, "GTK required (modal check)")
class MobileCloseTests(unittest.TestCase):
    def setUp(self):
        self.records = [{"id": "w1", "name": "UNO", "cwd": "/w", "agent": "shell"},
                        {"id": "w2", "name": "DOS", "cwd": "/w", "agent": "shell"}]
        self.workspaces = [{"id": "b1", "name": "CAJA", "kind": "local", "cwd": "/w", "windows": self.records},
                           {"id": "b2", "name": "OTRA", "kind": "local", "cwd": "/w", "windows": []}]
        self.calls, self.fail = [], None
        self.log = Capture()

        def close_window(workspace_id, window_id):
            if self.fail:
                raise self.fail
            self.calls.append(("terminal", workspace_id, window_id))
            box = next(item for item in self.workspaces if item["id"] == workspace_id)
            box["windows"] = [record for record in box["windows"] if record["id"] != window_id]

        def close_workspace(workspace_id):
            self.calls.append(("workspace", workspace_id))
            self.workspaces[:] = [item for item in self.workspaces if item["id"] != workspace_id]

        self.window = types.SimpleNamespace(store=types.SimpleNamespace(workspaces=self.workspaces, data={}),
                                            locked=False, surfaces={}, focused_surface=None, event_log=self.log,
                                            close_window_by_id=close_window, close_workspace_by_id=close_workspace)
        self.rpc = MobileRPC(self.window, types.SimpleNamespace(machine_id="fixture"), lambda callback: callback())

    def test_terminal_close_answers_the_whole_list_and_the_closed_id(self):
        params = json.loads(contract("box-close-v1", "close-terminal-request.json").read_text())
        params.update(workspace_id="b1", terminal_id="w1")
        result = self.rpc.dispatch("mobile.terminal.close", params, "peer")
        self.assertEqual(self.calls, [("terminal", "b1", "w1")])
        self.assertEqual(result["closed_terminal_id"], "w1")
        self.assertEqual([box["id"] for box in result["workspaces"]], ["b1", "b2"])
        self.assertEqual([t["id"] for t in result["workspaces"][0]["terminals"]], ["w2"])
        self.assertIn("box_close", result["capabilities"])
        expected = set(json.loads(contract("box-close-v1", "close-terminal-response.json").read_text()))
        self.assertTrue(expected <= set(result), expected - set(result))
        self.assertEqual(self.log.lines[-1][:2], ("info", "ui.box_closed"))
        self.assertEqual(self.log.lines[-1][2]["detail"], {"kind": "terminal", "source": "mobile"})

    def test_workspace_close_closes_the_box_with_its_windows(self):
        result = self.rpc.dispatch("workspace.close", {"workspace_id": "b1"}, "peer")
        self.assertEqual(self.calls, [("workspace", "b1")])
        self.assertEqual(result["closed_workspace_id"], "b1")
        self.assertEqual([box["id"] for box in result["workspaces"]], ["b2"])

    def test_contract_errors(self):
        for method, params in (("terminal.close", {"workspace_id": "b1"}), ("terminal.close", {"terminal_id": "w1"}),
                               ("workspace.close", {}), ("workspace.close", {"workspace_id": 7})):
            with self.subTest(params=params), self.assertRaises(RPCError) as caught:
                self.rpc.dispatch(method, params, "peer")
            self.assertEqual(caught.exception.code, "invalid_params")
        for method, params in (("terminal.close", {"workspace_id": "b1", "terminal_id": "nope"}),
                               ("workspace.close", {"workspace_id": "nope"})):
            with self.subTest(params=params), self.assertRaises(RPCError) as caught:
                self.rpc.dispatch(method, params, "peer")
            self.assertEqual(caught.exception.code, "not_found")
        error = json.loads(contract("box-close-v1", "close-error-not-found.json").read_text())
        self.assertEqual(error.get("code") or error.get("error", {}).get("code"), "not_found")
        self.fail = StateError("The selected workspace no longer exists")
        with self.assertRaises(RPCError) as caught:
            self.rpc.dispatch("terminal.close", {"workspace_id": "b1", "terminal_id": "w2"}, "peer")
        self.assertEqual(caught.exception.code, "close_failed")
        self.assertEqual(self.log.lines[-1][1], "ui.action_failed")
        self.assertEqual(self.log.lines[-1][2]["detail"]["action"], "close")
        self.assertEqual(self.calls, [])  # Nada cerrado a medias.

    def test_locked_desktop_closes_nothing(self):
        self.window.locked = True
        with self.assertRaises(RPCError) as caught:
            self.rpc.dispatch("workspace.close", {"workspace_id": "b1"}, "peer")
        self.assertEqual(caught.exception.code, "locked")
        self.assertEqual(self.calls, [])


@unittest.skipUnless(GTK_AVAILABLE, "GTK required")
class DesktopSelectionTests(unittest.TestCase):
    """El mismo cierre del escritorio; desde el móvil, en otra caja, no cambia la que se está viendo."""

    def desktop(self, selected):
        boxes = [{"id": "b1", "windows": [{"id": "w1"}]}, {"id": "b2", "windows": [{"id": "w2"}]}]
        store = types.SimpleNamespace(workspaces=boxes, data={"selectedWorkspaceId": selected}, closed=[])
        store.workspace = lambda identifier: next(box for box in boxes if box["id"] == identifier)
        store.close_window = lambda box, window: store.closed.append(("window", box, window))
        store.close_workspace = lambda box: (store.closed.append(("workspace", box)),
                                             boxes.remove(store.workspace(box)))
        desktop = types.SimpleNamespace(store=store, surfaces={}, built=[], selected=[])
        desktop.current_workspace = lambda: MainWindow.current_workspace(desktop)
        desktop.build_workspace = desktop.built.append
        desktop.select_workspace = lambda identifier=None: desktop.selected.append(identifier)
        return desktop

    def test_closing_a_window_in_another_box_keeps_the_desktop_where_it_was(self):
        desktop = self.desktop("b2")
        MainWindow.close_window_by_id(desktop, "b1", "w1")
        self.assertEqual(desktop.store.closed, [("window", "b1", "w1")])  # Recuperable en «Reabrir».
        self.assertEqual(desktop.selected, ["b2"])
        desktop = self.desktop("b1")
        MainWindow.close_window_by_id(desktop, "b1", "w1")
        self.assertEqual(desktop.selected, ["b1"])  # Como en el escritorio: se queda en su caja.

    def test_closing_a_box_keeps_the_other_selected_or_falls_back_like_the_desktop(self):
        desktop = self.desktop("b2")
        MainWindow.close_workspace_by_id(desktop, "b1")
        self.assertEqual(desktop.selected, ["b2"])
        desktop = self.desktop("b1")
        MainWindow.close_workspace_by_id(desktop, "b1")
        self.assertEqual(desktop.selected, [None])  # La caja vista se cerró: la primera, como siempre.


if __name__ == "__main__":
    unittest.main()
