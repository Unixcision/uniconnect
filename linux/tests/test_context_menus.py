"""Menús contextuales de Linux como los del Mac: solo lo que aplica, con separadores y submenús."""

from types import SimpleNamespace
import unittest

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False

from uniconnect.i18n import Translator
from uniconnect.relaunch_agents import cause_text, contract_causes

if GTK_AVAILABLE:
    from uniconnect.window import MainWindow
    from uniconnect.window_commands import WindowCommands


def labels(menu):
    """Lo que vería Dani: etiquetas en orden, «—» por separador y [submenú]."""
    result = []
    for item in menu.get_children():
        if isinstance(item, Gtk.SeparatorMenuItem):
            result.append("—")
        elif item.get_submenu() is not None:
            result.append((item.get_label(), labels(item.get_submenu())))
        else:
            result.append(item.get_label())
    return result


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required for menu behavior")
class MenuBuilderTests(unittest.TestCase):
    class Desktop:
        def __init__(self, hidden=()):
            self.hidden, self.ran = set(hidden), []
            self._ = lambda value: value

        build_context_menu = MainWindow.build_context_menu if GTK_AVAILABLE else None

        def action_visible(self, name):
            return name not in self.hidden

        def command_menu_item(self, name):
            return Gtk.MenuItem.new_with_label(name)

        def run_action(self, name):
            self.ran.append(name)

    def test_hidden_actions_empty_submenus_and_stray_separators_never_show(self):
        desktop = self.Desktop(hidden={"oculta", "sub-oculta"})
        menu = desktop.build_context_menu([None, "a", "oculta", None, None, "b", ("Mover", ["x", "y"]), None,
                                           ("Vacío", ["sub-oculta"]), None])
        self.assertEqual(labels(menu), ["a", "—", "b", ("Mover", ["x", "y"])])

    def test_items_run_their_action_even_inside_a_submenu(self):
        desktop = self.Desktop()
        menu = desktop.build_context_menu(["a", ("Mover", ["x"])])
        first, submenu = menu.get_children()
        first.activate()
        submenu.get_submenu().get_children()[0].activate()
        self.assertEqual(desktop.ran, ["a", "x"])


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required for menu behavior")
class VisibilityTests(unittest.TestCase):
    """Relanzar en una ventana sin IA relanzable no es «ahora no»: es nunca, así que no sale."""

    class Desktop:
        action_visible = WindowCommands.action_visible if GTK_AVAILABLE else None

        def __init__(self, kind, record=None, windows=None):
            self.workspace = {"id": "caja", "kind": kind, "windows": windows if windows is not None else
                              ([record] if record else [])}
            self.focused_surface = SimpleNamespace(record=record, workspace=self.workspace) if record else None

        def current_workspace(self):
            return self.workspace

    WINDOW_ACTIONS = ("relaunch_window", "continue_window", "adopt_antigravity_window", "upload", "kill_tmux",
                      "reconnect", "reset_window_name")

    def visible(self, desktop, names):
        return {name for name in names if desktop.action_visible(name)}

    def test_window_actions_follow_the_agent_and_the_box_kind(self):
        cases = {
            ("local", "shell", True): {"reconnect"},
            ("local", "codex", True): {"reconnect", "relaunch_window", "continue_window"},
            ("local", "agy", True): {"reconnect", "relaunch_window", "adopt_antigravity_window"},
            ("ssh", "codex", True): {"reconnect", "relaunch_window", "continue_window", "upload", "kill_tmux"},
            ("ssh", "codex", False): {"upload", "kill_tmux"},  # Sin tmux: ni reconectar ni relanzar.
            ("local", "claude", True): {"reconnect", "relaunch_window"},  # Probado en vivo en local (08-11).
            ("ssh", "claude", True): {"reconnect", "upload", "kill_tmux"},  # Por SSH aún no.
        }
        for (kind, agent, tmux), expected in cases.items():
            with self.subTest(kind=kind, agent=agent, tmux=tmux):
                record = {"id": "v", "agent": agent, **({"tmux": "uc-v"} if tmux else {})}
                self.assertEqual(self.visible(self.Desktop(kind, record), self.WINDOW_ACTIONS), expected)
        renamed = {"id": "v", "agent": "shell", "tmux": "uc-v", "originalName": "antes"}
        self.assertIn("reset_window_name", self.visible(self.Desktop("local", renamed), self.WINDOW_ACTIONS))

    def test_box_actions_appear_only_when_some_window_can_use_them(self):
        names = ("relaunch_workspace", "continue_workspace", "reconnect_workspace", "edit_ssh")
        shells = [{"id": "a", "agent": "shell", "tmux": "uc-a"}]
        self.assertEqual(self.visible(self.Desktop("local", windows=shells), names), {"reconnect_workspace"})
        mixed = shells + [{"id": "b", "agent": "codex", "tmux": "uc-b"}]
        self.assertEqual(self.visible(self.Desktop("ssh", windows=mixed), names), set(names))
        self.assertEqual(self.visible(self.Desktop("local", windows=[]), names), set())


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required for menu behavior")
class ReconnectBoxTests(unittest.TestCase):
    def test_reconnect_this_box_only_touches_its_own_tmux_windows(self):
        here, other = {"id": "aquí", "kind": "ssh"}, {"id": "otra", "kind": "ssh"}
        launched = []

        def surface(name, workspace, tmux=True):
            return SimpleNamespace(workspace=workspace, record={"id": name, **({"tmux": name} if tmux else {})},
                                   launch=lambda: launched.append(name))

        desktop = SimpleNamespace(current_workspace=lambda: here, surfaces={
            "1": surface("1", here), "2": surface("2", here, tmux=False), "3": surface("3", other)})
        MainWindow.action_reconnect_workspace(desktop)
        self.assertEqual(launched, ["1"])


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required for menu behavior")
class BoxListRoutingTests(unittest.TestCase):
    """Una ListBoxRow no tiene GdkWindow: el clic derecho lo recibe la lista y lo pasa a su fila."""

    def test_right_click_on_the_list_opens_the_menu_of_the_row_under_the_pointer(self):
        rows = {40: SimpleNamespace(workspace_id="caja")}
        opened = []
        desktop = SimpleNamespace(sidebar_workspace_context=lambda row, event: opened.append(row.workspace_id) or True)
        listing = SimpleNamespace(get_row_at_y=lambda y: rows.get(y))
        self.assertTrue(MainWindow.sidebar_list_context(desktop, listing, SimpleNamespace(button=3, y=40.7)))
        self.assertEqual(opened, ["caja"])
        self.assertFalse(MainWindow.sidebar_list_context(desktop, listing, SimpleNamespace(button=3, y=500)))
        self.assertFalse(MainWindow.sidebar_list_context(desktop, listing, SimpleNamespace(button=1, y=40)))
        self.assertEqual(opened, ["caja"])  # Ni el clic izquierdo ni el hueco abren nada.


class CauseTextTests(unittest.TestCase):
    def test_new_causes_read_from_the_contract_and_never_reach_the_user_as_codes(self):
        translate = Translator()
        for cause, text in contract_causes().items():
            with self.subTest(cause=cause):
                shown = cause_text(translate, cause)
                self.assertNotIn("uniconnect.relaunch.cause", shown)
                self.assertNotEqual(cause, shown)
        self.assertEqual(cause_text(translate, "sin_tmux"), contract_causes()["sin_tmux"])
        self.assertIn("inventada", cause_text(translate, "inventada"))  # Desconocida: genérica, pero dice cuál.


if __name__ == "__main__":
    unittest.main()
