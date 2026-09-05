"""GTK desktop coordinator: shared actions, workspace navigation and native panes."""

import copy
import json
import os
import shlex
import subprocess
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango

from .actions import ACTIONS
from .i18n import Translator
from .imports import Importer
from .runtime_transaction import RuntimeTransactionCoordinator
from .staged_terminal import StagedTerminal
from .terminal import TerminalSurface
from .transport import SSHCommand, Transport, TmuxCommand
from .window_commands import WindowCommands
from .window_notifications import WindowNotifications


class MainWindow(WindowCommands, WindowNotifications, Gtk.ApplicationWindow):
    def __init__(self, application, store, vault):
        super().__init__(application=application, title="UniConnect")
        self.get_style_context().add_class("uniconnect")
        self.store, self.vault = store, vault
        self._ = Translator(store.data.get("settings", {}).get("locale"))
        self.pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="uniconnect")
        self.font_scale = 1.0
        self.focused_surface = None
        self.surfaces, self.pages, self.notebooks = {}, {}, {}
        self.refreshing = False
        self._sidebar_refresh = 0
        self._building_workspace = 0
        self._closed = False
        self._runtime_rendering = False
        self._runtime_operation = None
        self.last_input, self.last_saved = time.monotonic(), 0
        self.locked = False
        self.fullscreened = False
        self.set_default_size(1350, 840)
        self.set_wmclass("uniconnect", "UniConnect")
        icon = Path(__file__).resolve().parents[2] / "docs/assets/logo-256.png"
        if icon.exists():
            self.set_icon_from_file(str(icon))
        self.connect("delete-event", self.on_delete)
        self.connect("key-press-event", self.on_activity)
        self.connect("button-press-event", self.on_activity)
        self.action_map = {a.name: a for a in ACTIONS}
        for action in ACTIONS:
            item = Gio.SimpleAction.new(action.name, None)
            item.connect("activate", self.activate_action, action.name)
            self.add_action(item)
        self.apply_shortcuts()
        self.apply_theme()
        header = Gtk.HeaderBar(title="UniConnect", show_close_button=True)
        header.get_style_context().add_class("uc-headerbar")
        header.set_subtitle("Linux")
        self.set_titlebar(header)
        for icon_name, action in (("view-sidebar-symbolic", "sidebar"), ("list-add-symbolic", "new_workspace")):
            button = self.action_button(icon_name, action)
            header.pack_start(button)
        header.pack_end(self.action_button("open-menu-symbolic", "palette"))
        header.pack_end(self.action_button("changes-prevent-symbolic", "lock"))
        header.pack_end(self.action_button("preferences-system-symbolic", "settings"))
        from .mobile_desktop import MobileDesktop
        try:
            self.mobile = MobileDesktop(self, header)
        except Exception:
            # A corrupt approval file blocks networking, never the user's desktop.
            self.mobile_access_error = self._("Could not load mobile access permissions")
            failed_mobile = Gtk.Button.new_from_icon_name("smartphone-symbolic", Gtk.IconSize.BUTTON)
            failed_mobile.set_tooltip_text(self.mobile_access_error)
            failed_mobile.connect("clicked", lambda *_: self.error(self.mobile_access_error))
            header.pack_end(failed_mobile)
        self.overlay = Gtk.Stack()
        self.add(self.overlay)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.overlay.add_named(content, "content")
        content.pack_start(self.build_menu(), False, False, 0)
        self.body = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        self.body.set_position(store.data.get("settings", {}).get("sidebarWidth", 255))
        content.pack_start(self.body, True, True, 0)
        sidebar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=12)
        sidebar.get_style_context().add_class("uc-sidebar")
        self.sidebar_search = Gtk.SearchEntry()
        self.sidebar_search.set_placeholder_text(self._("Find"))
        self.sidebar_search.connect("search-changed", lambda *_: self.refresh_sidebar())
        sidebar.pack_start(self.sidebar_search, False, False, 0)
        self.workspace_list = Gtk.ListBox()
        self.workspace_list.get_style_context().add_class("uc-workspaces")
        self.workspace_list.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.workspace_list.connect("row-selected", self.on_workspace_selected)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.workspace_list)
        sidebar.pack_start(scroll, True, True, 0)
        self.sidebar_actions = Gtk.Box(spacing=4)
        for icon_name, action in (("list-add-symbolic", "new_workspace"), ("document-open-symbolic", "import_config"),
                                  ("document-revert-symbolic", "reopen"), ("preferences-system-notifications-symbolic", "notifications")):
            self.sidebar_actions.pack_start(self.action_button(icon_name, action), False, False, 0)
        sidebar.pack_end(self.sidebar_actions, False, False, 0)
        self.body.pack1(sidebar, resize=False, shrink=False)
        self.workspace_stack = Gtk.Stack()
        self.workspace_stack.set_transition_type(Gtk.StackTransitionType.NONE)
        self.body.pack2(self.workspace_stack, resize=True, shrink=False)
        empty = self.empty_panel("Create your first workspace", "Local terminals and SSH sessions, ready when you return.", "new_workspace")
        self.workspace_stack.add_named(empty, "empty")
        status = Gtk.Box(margin=5, spacing=12)
        status.get_style_context().add_class("uc-status")
        self.status_label = Gtk.Label(xalign=0)
        status.pack_start(self.status_label, True, True, 6)
        content.pack_end(status, False, False, 0)
        lock = self.empty_panel("UniConnect", "Your sessions keep running while UniConnect is locked.", None)
        button = Gtk.Button(label=self._("Unlock"))
        button.connect("clicked", lambda *_: self.unlock())
        lock.pack_start(button, False, False, 12)
        self.overlay.add_named(lock, "locked")
        self.overlay.set_visible_child_name("content")
        self.refresh_sidebar()
        self.show_all()
        self.apply_sidebar_mode()
        self.select_workspace(self.store.data.get("selectedWorkspaceId"))
        # Cadence is product behavior; immediate mutations also persist synchronously.
        self._tick_source = GLib.timeout_add_seconds(8, self.tick)

    def action_button(self, icon, action):
        button = Gtk.Button.new_from_icon_name(icon, Gtk.IconSize.BUTTON)
        button.set_relief(Gtk.ReliefStyle.NONE)
        button.set_tooltip_text(self._(self.action_map[action].label))
        button.set_action_name(f"win.{action}")
        return button

    def empty_panel(self, title, detail, action):
        panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                        halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        heading = Gtk.Label()
        heading.set_markup(f'<span size="xx-large" weight="bold">{GLib.markup_escape_text(self._(title))}</span>')
        panel.pack_start(heading, False, False, 0)
        panel.pack_start(Gtk.Label(label=self._(detail)), False, False, 0)
        if action:
            button = Gtk.Button(label=self._(self.action_map[action].label))
            button.set_action_name(f"win.{action}")
            panel.pack_start(button, False, False, 15)
        return panel

    def build_menu(self):
        bar = Gtk.MenuBar()
        self.menu_items = []
        groups = {
            "UniConnect": ["about", "settings", "lock", "quit"],
            "File": ["new_workspace", "new_window", "new_conversation_window", "reopen_last", "reopen", "close_window", "close_other_windows", "close_workspace", "save", "import_config", "export_config", "restore_backup"],
            "Edit": ["copy", "paste", "find", "find_next", "find_previous", "hide_find", "find_selection", "send_ctrl_f"],
            "View": ["sidebar", "palette", "notifications", "notifications_latest_unread", "notifications_mark_all_read", "notifications_dismiss_all", "font_larger", "font_smaller", "font_reset", "split_right", "split_down", "equalize_panes", "maximize_pane", "focus_left", "focus_right", "focus_up", "focus_down", "fullscreen"],
            "Workspace": ["rename_workspace", "pin_workspace", "edit_ssh", "workspace_previous", "workspace_next", "workspace_up", "workspace_down", "workspace_first", "window_previous", "window_next", "rename_window", "reconnect", "reconnect_all", "notifications_toggle_workspace", "notifications_toggle_window", "upload", "kill_tmux"],
            "Help": ["help", "help_shortcuts", "help_settings", "report_issue"],
        }
        for label, names in groups.items():
            item = Gtk.MenuItem(label=self._(label))
            menu = Gtk.Menu()
            for name in names:
                action = self.command_menu_item(name)
                action.connect("activate", lambda _, n=name: self.run_action(n))
                self.menu_items.append((name, action))
                menu.append(action)
            menu.connect("show", lambda *_: self.refresh_actions())
            item.set_submenu(menu)
            bar.append(item)
        return bar

    def command_menu_item(self, name):
        item = Gtk.ImageMenuItem.new_with_label(self.action_label(name))
        icon = ("edit-delete-symbolic" if name.startswith("close") or name in ("kill_tmux", "notifications_dismiss_all") else
                "mail-mark-read-symbolic" if name == "notifications_mark_all_read" else
                "mail-mark-unread-symbolic" if name.startswith("notifications_toggle") else
                "go-jump-symbolic" if name == "notifications_latest_unread" else
                "list-add-symbolic" if name.startswith("new") else
                "view-refresh-symbolic" if name.startswith("reconnect") else
                "document-save-symbolic" if name in ("save", "export_config") else
                "system-run-symbolic")
        item.set_image(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.MENU))
        item.set_always_show_image(True)
        binding = self.store.data.get("settings", {}).get("shortcuts", {}).get(name, self.action_map[name].shortcut)
        if binding:
            item.get_child().set_accel(*Gtk.accelerator_parse(binding))
        item.set_sensitive(self.action_enabled(name))
        return item

    def context_menu(self, names, event):
        menu = Gtk.Menu()
        for name in names:
            item = self.command_menu_item(name)
            item.connect("activate", lambda _, n=name: self.run_action(n))
            menu.append(item)
        menu.show_all()
        menu.popup_at_pointer(event)

    def activate_action(self, _, parameter, name):
        self.run_action(name)

    def run_action(self, name):
        if not self.action_enabled(name):
            return
        method = getattr(self, f"action_{name}", None)
        try:
            for kind in ("workspace", "window"):
                number = name.removeprefix(kind + "_")
                if name.startswith(kind + "_") and number.isdigit():
                    return self.select_number(kind, int(number))
            if method:
                method()
        except Exception as error:
            self.error(error)

    def refresh_sidebar(self):
        # Rebuild only after the GTK event currently using a row has unwound.
        # Removing a focused row from its own focus/selection signal can crash GTK.
        if not self._closed and not self._sidebar_refresh:
            self._sidebar_refresh = GLib.idle_add(self._render_sidebar)
        if hasattr(self, "mobile"):
            self.mobile.workspace_changed()

    def _render_sidebar(self):
        self._sidebar_refresh = 0
        if self._closed or not hasattr(self, "workspace_list"):
            return False
        self.refreshing = True
        selected = self.store.data.get("selectedWorkspaceId")
        query = self.sidebar_search.get_text().lower()
        for row in self.workspace_list.get_children():
            self.workspace_list.remove(row)
        for workspace in self.store.workspaces:
            if query and query not in (workspace["name"] + " " + " ".join(w["name"] for w in workspace.get("windows", []))).lower():
                continue
            row = Gtk.ListBoxRow()
            row.get_style_context().add_class("uc-workspace")
            row.workspace_id = workspace["id"]
            body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5, margin=10)
            title = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END)
            color = workspace.get("color") or "#66b9ff"
            if not color.startswith("#") or len(color) not in (4, 7, 9):
                color = "#66b9ff"
            unread = any(w.get("unread") for w in workspace.get("windows", []))
            compact = self.store.data.get("settings", {}).get("compactSidebar", False)
            name = workspace["name"][:2].upper() if compact else workspace["name"]
            title.set_markup(f'<span foreground="{color}">●</span> <b>{GLib.markup_escape_text(name)}</b>' + ("  ●" if unread else ""))
            body.pack_start(title, False, False, 0)
            if not compact:
                detail = f'{workspace["kind"].upper()}  ·  {len(workspace.get("windows", []))}'
                body.pack_start(Gtk.Label(label=detail, xalign=0), False, False, 0)
                for window in workspace.get("windows", []):
                    label = Gtk.Label(label="  " + window["name"], xalign=0, ellipsize=Pango.EllipsizeMode.END)
                    label.get_style_context().add_class("dim-label")
                    body.pack_start(label, False, False, 0)
            row.set_tooltip_text(workspace["name"] + "\n" + "\n".join(w["name"] for w in workspace.get("windows", [])))
            row.add(body)
            row.connect("button-press-event", self.workspace_context, workspace)
            self.workspace_list.add(row)
            if workspace["id"] == selected:
                self.workspace_list.select_row(row)
        self.workspace_list.show_all()
        self.refreshing = False
        self.refresh_actions()
        return False

    def workspace_context(self, _, event, workspace):
        if event.button == 3:
            self._notification_context_selection = True
            try:
                self.select_workspace(workspace["id"])
                if self.focused_surface:
                    self._notification_preserve_focus_id = self.focused_surface.record["id"]
            finally:
                self._notification_context_selection = False
            self.context_menu(["new_window", "rename_workspace", "pin_workspace", "edit_ssh", "workspace_up", "workspace_down", "workspace_first", "reconnect_all", "notifications_toggle_workspace", "close_workspace"], event)
            return True
        return False

    def on_workspace_selected(self, _, row):
        if row and not self.refreshing:
            self.select_workspace(row.workspace_id)

    def current_workspace(self):
        selected = self.store.data.get("selectedWorkspaceId")
        return next((w for w in self.store.workspaces if w["id"] == selected), None)

    def select_workspace(self, workspace_id=None):
        workspace = next((w for w in self.store.workspaces if w["id"] == workspace_id), None)
        if workspace is None and self.store.workspaces:
            workspace = self.store.workspaces[0]
        if workspace is None:
            self.workspace_stack.set_visible_child_name("empty")
            self.focused_surface = None
            self.refresh_actions()
            return
        self.store.data["selectedWorkspaceId"] = workspace["id"]
        if workspace["id"] not in self.pages:
            self.build_workspace(workspace)
        self.workspace_stack.set_visible_child_name(workspace["id"])
        surface = self.surfaces.get(workspace.get("selectedWindowId"))
        if surface is None:
            surface = next((self.surfaces.get(w["id"]) for w in workspace.get("windows", [])), None)
        self.focused_surface = surface
        if surface:
            parent = surface.get_parent()
            if isinstance(parent, Gtk.Notebook):
                parent.set_current_page(parent.page_num(surface))
            surface.terminal.grab_focus()
        self.refresh_sidebar()
        self.persist()
        self.refresh_actions()

    def build_workspace(self, workspace, create_ids=()):
        self._building_workspace += 1
        try:
            return self._build_workspace(workspace, create_ids)
        finally:
            self._building_workspace -= 1

    @staticmethod
    def _detach_terminals(container):
        # Detach from the actual GTK tree, including a terminal whose model has
        # just moved to another pane/workspace. Destroying its old parent first
        # leaves a destroyed VTE widget that can crash GTK during the next layout.
        for child in list(container.get_children()):
            if isinstance(child, TerminalSurface):
                container.remove(child)
            elif isinstance(child, Gtk.Container):
                MainWindow._detach_terminals(child)

    def _build_workspace(self, workspace, create_ids=()):
        if workspace["id"] in self.pages:
            previous = self.pages.pop(workspace["id"])
            self._detach_terminals(previous)
            self.workspace_stack.remove(previous)
            previous.destroy()
        for key in list(self.notebooks):
            if key[0] == workspace["id"]:
                del self.notebooks[key]
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        top = Gtk.Box(spacing=8, margin=8)
        top.get_style_context().add_class("uc-workspace-header")
        title = Gtk.Label(label=workspace["name"], xalign=0)
        top.pack_start(title, True, True, 5)
        top.pack_end(self.action_button("list-add-symbolic", "new_window"), False, False, 0)
        top.pack_end(self.action_button("view-refresh-symbolic", "reconnect"), False, False, 0)
        box.pack_start(top, False, False, 0)
        if not workspace.get("windows"):
            box.pack_start(self.empty_panel("Create a window to start working", "", "new_window"), True, True, 0)
        else:
            pane_ids = list(dict.fromkeys(w.setdefault("paneId", "main") for w in workspace["windows"]))
            notebooks = []
            for pane_id in pane_ids:
                notebook = Gtk.Notebook()
                notebook.get_style_context().add_class("uc-terminal-tabs")
                notebook.set_scrollable(True)
                notebook.set_group_name(f'uc-{workspace["id"]}')
                notebook.connect("switch-page", self.on_tab_selected, workspace)
                notebook.connect("page-reordered", self.on_tab_reordered, workspace)
                self.notebooks[(workspace["id"], pane_id)] = notebook
                for window in [w for w in workspace["windows"] if w["paneId"] == pane_id]:
                    surface = self.surfaces.get(window["id"])
                    if surface:
                        parent = surface.get_parent()
                        if parent:
                            parent.remove(surface)
                    else:
                        surface = TerminalSurface(self, workspace, window, window["id"] in create_ids)
                        self.surfaces[window["id"]] = surface
                    label = Gtk.Box(spacing=6)
                    label.pack_start(Gtk.Label(label=("• " if window.get("pinned") else "") + window["name"]), True, True, 0)
                    close = Gtk.Button.new_from_icon_name("window-close-symbolic", Gtk.IconSize.MENU)
                    close.set_relief(Gtk.ReliefStyle.NONE)
                    close.connect("clicked", lambda _, s=surface: self.close_surface(s))
                    label.pack_end(close, False, False, 0)
                    label.show_all()
                    tab = Gtk.EventBox()
                    tab.add(label)
                    tab.connect("button-press-event", self.tab_context, surface)
                    tab.show_all()
                    notebook.append_page(surface, tab)
                    notebook.set_tab_reorderable(surface, True)
                notebooks.append(notebook)
            content = notebooks[0]
            for index, notebook in enumerate(notebooks[1:]):
                axis = workspace.get("splitAxis", "horizontal")
                paned = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL if axis == "vertical" else Gtk.Orientation.HORIZONTAL)
                paned.pack1(content, True, False)
                paned.pack2(notebook, True, False)
                paned.set_position(workspace.get("splitPosition", 450))
                paned.connect("notify::position", self.on_split_position, workspace)
                content = paned
            box.pack_start(content, True, True, 0)
        self.pages[workspace["id"]] = box
        self.workspace_stack.add_named(box, workspace["id"])
        box.show_all()
        self.apply_pane_visibility(workspace)

    def tab_context(self, _, event, surface):
        if event.button == 3:
            self._notification_context_selection = True
            try:
                self.select_surface(surface)
                self._notification_preserve_focus_id = surface.record["id"]
            finally:
                self._notification_context_selection = False
            self.context_menu(["new_conversation_window", "rename_window", "reset_window_name", "pin_window", "move_window_left", "move_window_right",
                               "maximize_pane", "notifications_toggle_window", "close_window", "close_left_windows", "close_right_windows",
                               "close_other_windows", "kill_tmux"], event)
            return True
        return False

    def on_split_position(self, paned, _, workspace):
        if self._building_workspace:
            return
        workspace["splitPosition"] = paned.get_position()

    def on_tab_selected(self, notebook, surface, page, workspace):
        if not self._building_workspace and isinstance(surface, TerminalSurface):
            self.focused_surface = surface
            workspace["selectedWindowId"] = surface.record["id"]
            self.persist()
            self.refresh_actions()

    def on_tab_reordered(self, notebook, child, page, workspace):
        if self._building_workspace:
            return
        ordered = [notebook.get_nth_page(i).record["id"] for i in range(notebook.get_n_pages())]
        original = workspace["windows"]
        members = {wid: next(w for w in original if w["id"] == wid) for wid in ordered}
        iterator = iter(ordered)
        workspace["windows"] = [members[next(iterator)] if w["id"] in members else w for w in original]
        self.persist()

    def connection(self, workspace):
        if self.vault.locked:
            if not self.unlock():
                raise RuntimeError(self._("Private vault"))
        return self.vault.get(workspace["credentialId"])

    def persist(self):
        if self._runtime_rendering:
            return
        try:
            self.store.save()
            self.last_saved = time.time()
            if hasattr(self, "status_label"):
                count = sum(len(w.get("windows", [])) for w in self.store.workspaces)
                self.status_label.set_text(f'{self._("Saved")} {time.strftime("%H:%M:%S")}  ·  {len(self.store.workspaces)} / {count}')
        except Exception as error:
            if hasattr(self, "status_label"):
                self.status_label.set_text(self._(str(error)))

    def tick(self):
        if self._closed:
            return False
        self.persist()
        auto = self.store.data.get("settings", {}).get("autoLockMinutes", 0)
        if auto and not self.locked and time.monotonic() - self.last_input >= auto * 60:
            self.action_lock()
        return True

    def on_activity(self, *_):
        self.last_input = time.monotonic()
        return False

    def background(self, work, done=None):
        future = self.pool.submit(work)
        def finished(result):
            def deliver():
                try:
                    value = result.result()
                    if done:
                        done(value)
                except Exception as error:
                    self.error(error)
                return False
            GLib.idle_add(deliver)
        future.add_done_callback(finished)

    def error(self, error):
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.ERROR,
                                   buttons=Gtk.ButtonsType.NONE, text=self._("Error"))
        dialog.add_button(self._("Close"), Gtk.ResponseType.CLOSE)
        dialog.format_secondary_text(self._(str(error)))
        dialog.run()
        dialog.destroy()

    def fields_dialog(self, title, fields, accept="Apply"):
        dialog = Gtk.Dialog(title=self._(title), transient_for=self, modal=True)
        dialog.add_button(self._("Cancel"), Gtk.ResponseType.CANCEL)
        dialog.add_button(self._(accept), Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.OK)
        grid = Gtk.Grid(column_spacing=15, row_spacing=12, margin=20)
        widgets = {}
        for index, (key, label, value, kind) in enumerate(fields):
            grid.attach(Gtk.Label(label=self._(label), xalign=0), 0, index, 1, 1)
            if isinstance(kind, list):
                widget = Gtk.ComboBoxText()
                for option in kind:
                    widget.append(option, self._(option))
                widget.set_active_id(value)
            else:
                widget = Gtk.Entry(text=str(value or ""), width_chars=48)
                widget.set_activates_default(True)
                if kind == "password":
                    widget.set_visibility(False)
                    widget.set_input_purpose(Gtk.InputPurpose.PASSWORD)
            grid.attach(widget, 1, index, 1, 1)
            widgets[key] = widget
        if len(fields) > 10:
            scroll = Gtk.ScrolledWindow()
            scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            scroll.set_min_content_height(520)
            scroll.add(grid)
            dialog.get_content_area().add(scroll)
        else:
            dialog.get_content_area().add(grid)
        dialog.show_all()
        result = None
        if dialog.run() == Gtk.ResponseType.OK:
            result = {key: (widget.get_active_id() if isinstance(widget, Gtk.ComboBoxText) else widget.get_text()) for key, widget in widgets.items()}
        dialog.destroy()
        return result

    def choose_file(self, title, save=False):
        dialog = Gtk.FileChooserDialog(title=self._(title), transient_for=self,
                                       action=Gtk.FileChooserAction.SAVE if save else Gtk.FileChooserAction.OPEN)
        dialog.add_buttons(self._("Cancel"), Gtk.ResponseType.CANCEL, self._("Save" if save else "Open"), Gtk.ResponseType.OK)
        if save:
            dialog.set_do_overwrite_confirmation(True)
            dialog.set_current_name("workspaces.uniconnect")
        path = dialog.get_filename() if dialog.run() == Gtk.ResponseType.OK else None
        dialog.destroy()
        return path

    def action_new_workspace(self):
        result = self.fields_dialog("New workspace", [("name", "Name", "", "text"),
            ("kind", "Workspace", "local", ["local", "ssh"]),
            ("cwd", "Folder", str(Path.home()), "text"),
            ("connect", "Connection command", "", "password"), ("color", "Color", "#66b9ff", "text")], "Create")
        if not result or not result["name"].strip():
            return
        workspace = {"id": str(uuid.uuid4()), "name": result["name"].strip(), "kind": result["kind"],
                     "cwd": result["cwd"], "color": result["color"], "windows": []}
        if workspace["kind"] == "ssh":
            command = SSHCommand.parse(result["connect"])
            workspace["credentialId"] = self.vault.put(result["connect"])
            workspace["hostLabel"] = str(command.endpoint_key())
        elif not Path(workspace["cwd"]).expanduser().is_dir():
            raise ValueError(self._("The folder does not exist"))
        self.commit_new_workspace(workspace, select=True)

    def commit_new_workspace(self, workspace, *, select=False):
        """Single creation mutation for desktop dialogs and explicit mobile RPCs."""
        self.store.workspaces.append(workspace)
        try:
            self.store.save()
        except Exception:
            self.store.workspaces.remove(workspace)
            raise
        self.refresh_sidebar()
        if select:
            self.select_workspace(workspace["id"])
        return workspace

    def create_mobile_workspace(self, params):
        from .mobile_protocol import RPCError
        if (self.store._active_transaction is not None or self.store.journal_path.exists()
                or self._runtime_operation and self._runtime_operation.active):
            raise RPCError("busy", self._("Importación en curso"))
        name, kind = params.get("name"), params.get("kind", "local")
        if not isinstance(name, str) or not name.strip() or len(name.encode()) > 512 or not name.isprintable():
            raise RPCError("invalid_params", self._("Nombre de espacio de trabajo no válido"))
        workspace = {"id": str(uuid.uuid4()), "name": name.strip(), "kind": kind, "windows": []}
        if kind == "ssh":
            source = next((item for item in self.store.workspaces
                           if item["id"] == params.get("source_workspace_id") and item["kind"] == "ssh"), None)
            if source is None:
                raise RPCError("invalid_params", self._("Elige un espacio SSH existente del que heredar la conexión"))
            for key in ("credentialId", "hostLabel", "cwd", "color"):
                if key in source:
                    workspace[key] = source[key]
        elif kind == "local":
            directory = params.get("directory")
            if not isinstance(directory, str) or not directory.startswith("/") or not Path(directory).is_dir():
                raise RPCError("invalid_params", self._("The folder does not exist"))
            workspace["cwd"] = directory
        else:
            raise RPCError("invalid_params", self._("Tipo de espacio de trabajo no válido"))
        return self.commit_new_workspace(workspace)

    def create_mobile_window(self, workspace, params):
        from .mobile_protocol import RPCError
        if (self.store._active_transaction is not None or self.store.journal_path.exists()
                or self._runtime_operation and self._runtime_operation.active):
            raise RPCError("busy", self._("Importación en curso"))
        name, agent = params.get("name"), params.get("agent", "terminal")
        if not isinstance(name, str) or not name.strip() or len(name.encode()) > 512 or not name.isprintable():
            raise RPCError("invalid_params", self._("Nombre de ventana no válido"))
        if agent not in ("terminal", "claude", "codex", "agy", "grok") or workspace["kind"] == "ssh" and agent != "terminal":
            raise RPCError("invalid_params", self._("Agente no válido para este espacio de trabajo"))
        identifier = str(uuid.uuid4())
        directory = params.get("directory") or workspace.get("cwd") or str(Path.home())
        if not isinstance(directory, str) or not directory.startswith("/") or not directory.isprintable() or len(directory) > 4096:
            raise RPCError("invalid_params", self._("Carpeta no válida"))
        if workspace["kind"] == "local" and (params.get("tmux_session") is not None or not Path(directory).is_dir()):
            raise RPCError("invalid_params", self._("The folder does not exist"))
        session = params.get("tmux_session") if workspace["kind"] == "ssh" else "uc-" + identifier.replace("-", "")
        try:
            TmuxCommand.validate_name(session)
        except Exception as error:
            raise RPCError("invalid_params", self._("Nombre de sesión tmux no válido")) from error
        socket_name = (next((item.get("tmuxSocket") for item in workspace["windows"] if item.get("tmuxSocket")), "uniconnect")
                       if workspace["kind"] == "ssh" else "uniconnect-local")
        if any(item.get("tmux") == session and (item.get("tmuxSocket") or socket_name) == socket_name
               for item in workspace["windows"]):
            raise RPCError("conflict", self._("This session is already open in another window"))
        record = {"id": identifier, "name": name.strip(), "agent": "shell" if agent == "terminal" else agent,
                  "cwd": directory, "tmux": session, "tmuxSocket": socket_name, "paneId": "main"}
        self.commit_new_window(workspace, record, select=False)
        return record

    def commit_new_window(self, workspace, record, *, select=True):
        """Persist one named window before asynchronously preparing its durable client."""
        previous_selected = workspace.get("selectedWindowId")
        workspace["windows"].append(record)
        if select:
            workspace["selectedWindowId"] = record["id"]
        try:
            self.store.save()
        except Exception:
            workspace["windows"].remove(record)
            if previous_selected is None:
                workspace.pop("selectedWindowId", None)
            else:
                workspace["selectedWindowId"] = previous_selected
            raise
        self.build_workspace(workspace, create_ids=(record["id"],))
        self.refresh_sidebar()
        if select:
            self.select_workspace(workspace["id"])

    def action_new_window(self, pane_id=None, *, conversation=False):
        workspace = self.current_workspace()
        if workspace is None:
            return self.action_new_workspace()
        source = (self.focused_surface.record if self.focused_surface
                  and self.focused_surface.workspace is workspace else {})
        agent = source.get("agent") if conversation else "shell"
        if agent not in ("shell", "codex", "claude", "agy", "grok", "custom") or (conversation and agent == "shell"):
            agent = "claude"
        directory = source.get("cwd") or workspace.get("cwd") or str(Path.home())
        fields = [("name", "Name", self._("Conversación") if conversation else "Terminal", "text"),
                  ("agent", "Terminal", agent, ["shell", "codex", "claude", "agy", "grok", "custom"]),
                  ("cwd", "Folder", directory, "text")]
        if not conversation:
            fields.append(("sessionId", "Session ID", "", "text"))
        if workspace["kind"] == "ssh":
            fields.append(("tmux", "tmux session", "uc-" + uuid.uuid4().hex[:12], "text"))
        # Never copy a custom launch: it may contain --resume for the current conversation.
        fields.append(("customCommand", "Comando personalizado (ejecutable y argumentos)", "", "text"))
        title = "Nueva conversación en otra ventana" if conversation else "New window"
        result = self.fields_dialog(title, fields, "Create")
        if not result:
            return
        result.update(id=str(uuid.uuid4()), paneId=pane_id or source.get("paneId", "main"),
                      tmuxSocket=source.get("tmuxSocket") or "uniconnect")
        if workspace["kind"] == "local":
            result["tmuxSocket"] = "uniconnect-local"
            result["tmux"] = "uc-" + result["id"].replace("-", "")
        if conversation or not result.get("sessionId"):
            result.pop("sessionId", None)
        custom_command = result.pop("customCommand", "")
        if result["agent"] == "custom":
            try:
                result["commandArgv"] = shlex.split(custom_command)
            except ValueError as exc:
                raise ValueError(self._("Revisa las comillas del comando personalizado.")) from exc
            if not result["commandArgv"]:
                raise ValueError(self._("Indica el ejecutable y los argumentos del comando personalizado."))
        TmuxCommand.agent_argv(result)  # Validate before persisting or opening a terminal.
        if conversation and any(item.get("tmux") == result["tmux"]
                                and (item.get("tmuxSocket") or "uniconnect") == result["tmuxSocket"]
                                for item in workspace["windows"]):
            raise ValueError(self._("Elige una sesión tmux nueva para conservar la conversación actual."))
        def created(prepared=None):
            if conversation and prepared is not None and not prepared["created"]:
                raise ValueError(self._("La sesión tmux ya existe. Elige otro nombre para una conversación nueva."))
            self.commit_new_window(workspace, result)
        if workspace["kind"] == "ssh":
            transport = Transport(SSHCommand.parse(self.connection(workspace)), socket_name=result["tmuxSocket"])
            self.background(lambda: transport.ensure_session(result), created)
        else:
            created()

    def close_surface(self, surface):
        # Persist the recoverable entry before detaching a live terminal.
        self.store.close_window(surface.workspace["id"], surface.record["id"])
        surface.dispose()
        self.surfaces.pop(surface.record["id"], None)
        self.build_workspace(surface.workspace)
        self.select_workspace(surface.workspace["id"])

    def action_close_window(self):
        if self.focused_surface and self.confirm("Close this window?", self.focused_surface.record["name"]):
            self.close_surface(self.focused_surface)

    def action_close_workspace(self):
        workspace = self.current_workspace()
        if not workspace:
            return
        if not self.confirm("Close this workspace?", workspace["name"]):
            return
        self.store.close_workspace(workspace["id"])
        for record in workspace["windows"]:
            surface = self.surfaces.pop(record["id"], None)
            if surface:
                surface.dispose()
        self.select_workspace()

    def action_reopen(self):
        closed = self.store.data.get("closed", [])
        if not closed:
            return
        dialog = Gtk.Dialog(title=self._("Closed"), transient_for=self, modal=True)
        dialog.add_button(self._("Close"), Gtk.ResponseType.CLOSE)
        for item in closed[:40]:
            name = item.get("name") or item.get("window", item.get("workspace", {})).get("name", item["id"])
            button = Gtk.Button(label=self._("Reopen") + " · " + name)
            def reopen(_, saved=item):
                self.store.restore_closed(saved["id"])
                self.reload_workspaces()
                dialog.response(Gtk.ResponseType.CLOSE)
            button.connect("clicked", reopen)
            dialog.get_content_area().pack_start(button, False, False, 4)
        dialog.show_all()
        dialog.run()
        dialog.destroy()

    def reload_workspaces(self):
        for workspace in self.store.workspaces:
            if workspace["id"] in self.pages:
                self.build_workspace(workspace)
        self.select_workspace(self.store.data.get("selectedWorkspaceId"))

    def stage_runtime(self, workspaces, connections, mutate, *, reason, on_complete=None, timeout=20):
        """Publish an import/endpoint change only after every replacement attaches.

        All provisional clients are attach-only and use private model copies.
        The old widgets/clients remain available until the durable transaction
        commits; a failed partial widget swap restores the same original objects.
        """
        if self._runtime_operation and self._runtime_operation.active:
            raise ValueError("Ya hay una conexión en preparación; espera o cancélala.")
        if self._closed:
            raise ValueError("La aplicación se está cerrando.")
        workspaces = copy.deepcopy(workspaces)
        affected = {workspace["id"] for workspace in workspaces}
        identifiers = [record["id"] for workspace in workspaces for record in workspace["windows"]]
        if len(set(identifiers)) != len(identifiers):
            raise ValueError("La configuración contiene ventanas duplicadas.")
        registry = {key: surface for key, surface in getattr(self, "_terminal_owners", {}).items()
                    if surface.record["id"] not in identifiers}
        candidates = []
        try:
            for workspace in workspaces:
                for record in workspace["windows"]:
                    candidate = StagedTerminal(self, workspace, record,
                                               connection=connections.get(workspace["id"]), registry=registry)
                    previous = self.surfaces.get(record["id"])
                    if previous:
                        candidate.surface.terminal.set_size(max(1, previous.terminal.get_column_count()),
                                                            max(1, previous.terminal.get_row_count()))
                    candidates.append(candidate)
        except Exception:
            for candidate in candidates:
                candidate.stop_candidate()
            raise
        snapshot = {}
        progress = Gtk.Dialog(title="Comprobando conexiones", transient_for=self, modal=True)
        progress.add_button(self._("Cancel"), Gtk.ResponseType.CANCEL)
        progress.get_content_area().add(Gtk.Label(
            label="Las sesiones actuales seguirán abiertas hasta verificar todas las conexiones.", margin=20))
        operation = RuntimeTransactionCoordinator(
            self.store, schedule=lambda delay, callback: GLib.timeout_add(max(1, int(delay * 1000)), callback),
            cancel_timer=GLib.source_remove, defer=GLib.idle_add)
        self._runtime_operation = operation

        def render(callback):
            self._runtime_rendering = True
            self._building_workspace += 1
            try:
                callback()
            finally:
                self._building_workspace -= 1
                self._runtime_rendering = False

        def publish(prepared, value):
            snapshot.update(surfaces=dict(self.surfaces), pages=set(self.pages),
                            registry=dict(getattr(self, "_terminal_owners", {})), focused=self.focused_surface)
            def swap():
                for candidate in prepared:
                    workspace = self.store.workspace(candidate.workspace["id"])
                    record = next(item for item in workspace["windows"] if item["id"] == candidate.record["id"])
                    if record.get("tmux") != candidate.record.get("tmux"):
                        raise ValueError("La sesión propuesta cambió durante la preparación.")
                    surface = candidate.adopt(workspace, record)
                    surface.update_status(surface.status)
                    self.surfaces[record["id"]] = surface
                for workspace in self.store.workspaces:
                    if workspace["id"] in affected:
                        self.build_workspace(workspace)
                self.select_workspace(self.store.data.get("selectedWorkspaceId"))
            render(swap)

        def restore():
            def undo():
                for identifier in list(self.pages):
                    if identifier in affected or identifier not in snapshot["pages"]:
                        page = self.pages.pop(identifier)
                        self._detach_terminals(page)
                        self.workspace_stack.remove(page)
                        page.destroy()
                        for key in list(self.notebooks):
                            if key[0] == identifier:
                                del self.notebooks[key]
                self.surfaces = snapshot["surfaces"]
                self._terminal_owners = snapshot["registry"]
                for workspace in self.store.workspaces:
                    if workspace["id"] in affected and workspace["id"] in snapshot["pages"]:
                        self.build_workspace(workspace)
                self.select_workspace(self.store.data.get("selectedWorkspaceId"))
                self.focused_surface = snapshot["focused"]
            render(undo)

        def retire():
            for identifier in identifiers:
                original = snapshot["surfaces"].get(identifier)
                if original:
                    original.dispose()
            for candidate in candidates:
                candidate.release()

        def completed(result):
            progress.destroy()
            if on_complete:
                on_complete(result)
            elif not result.success and result.code != "cancelled" and not self._closed:
                detail = ("El estado cambió durante la comprobación. Repite la operación."
                          if result.code == "runtime-state-changed" else
                          "No se pudo completar la conexión. Se han conservado las sesiones anteriores.")
                if result.cleanup_errors:
                    detail += " Hay una recuperación pendiente; revisa el estado antes de continuar."
                self.error(detail)

        progress.connect("response", lambda *_: operation.cancel() if operation.active else None)
        progress.show_all()
        try:
            operation.start(candidates, mutate=mutate, publish=publish, restore_runtime=restore,
                            retire_originals=retire, on_complete=completed, timeout=timeout, reason=reason)
        except Exception:
            progress.destroy()
            for candidate in candidates:
                candidate.stop_candidate()
            raise
        return operation

    def action_save(self):
        self.persist()
        self.store.checkpoint("manual")

    def action_rename_workspace(self):
        workspace = self.current_workspace()
        if workspace:
            result = self.fields_dialog("Rename workspace", [("name", "Name", workspace["name"], "text"), ("color", "Color", workspace.get("color", "#66b9ff"), "text")])
            if result and result["name"].strip():
                workspace.update(result)
                self.persist()
                self.build_workspace(workspace)
                self.select_workspace(workspace["id"])

    def action_rename_window(self):
        surface = self.focused_surface
        if surface:
            result = self.fields_dialog("Rename window", [("name", "Name", surface.record["name"], "text")])
            if result and result["name"].strip():
                surface.record.setdefault("originalName", surface.record["name"])
                surface.record.update(result)
                self.persist()
                self.build_workspace(surface.workspace)
                self.select_workspace(surface.workspace["id"])

    def action_reconnect(self):
        if self.focused_surface:
            self.focused_surface.launch()

    def action_reconnect_all(self):
        for surface in self.surfaces.values():
            if surface.workspace["kind"] == "ssh":
                surface.launch()

    def action_split_right(self):
        workspace = self.current_workspace()
        if workspace:
            workspace["splitAxis"] = "horizontal"
            self.action_new_window("pane-" + uuid.uuid4().hex[:8])

    def action_split_down(self):
        workspace = self.current_workspace()
        if workspace:
            workspace["splitAxis"] = "vertical"
            self.action_new_window("pane-" + uuid.uuid4().hex[:8])

    def action_sidebar(self):
        settings = self.store.data.setdefault("settings", {})
        compact = not settings.get("compactSidebar", False)
        settings["compactSidebar"] = compact
        self.apply_sidebar_mode()
        self.refresh_sidebar()
        self.persist()

    def apply_sidebar_mode(self):
        settings = self.store.data.get("settings", {})
        compact = settings.get("compactSidebar", False)
        self.sidebar_actions.set_orientation(Gtk.Orientation.VERTICAL if compact else Gtk.Orientation.HORIZONTAL)
        self.sidebar_search.set_visible(not compact)
        self.body.set_position(78 if compact else settings.get("sidebarWidth", 255))

    def action_copy(self):
        if self.focused_surface:
            self.focused_surface.copy()

    def action_paste(self):
        if self.focused_surface:
            self.focused_surface.paste()

    def action_find(self):
        if self.focused_surface:
            self.focused_surface.show_find()

    def action_font_larger(self):
        self.font_scale = min(3, self.font_scale + 0.1)
        self.refresh_appearance()

    def action_font_smaller(self):
        self.font_scale = max(0.5, self.font_scale - 0.1)
        self.refresh_appearance()

    def action_font_reset(self):
        self.font_scale = 1.0
        self.refresh_appearance()

    def refresh_appearance(self):
        for surface in self.surfaces.values():
            surface.apply_appearance()

    def action_fullscreen(self):
        self.fullscreened = not self.fullscreened
        self.fullscreen() if self.fullscreened else self.unfullscreen()

    def action_palette(self):
        dialog = Gtk.Dialog(title=self._("Command palette"), transient_for=self, modal=True)
        dialog.set_default_size(520, 560)
        search = Gtk.SearchEntry()
        search.set_placeholder_text(self._("Find"))
        listing = Gtk.ListBox()
        listing.set_filter_func(lambda row: search.get_text().lower() in row.search_text)
        search.connect("search-changed", lambda *_: listing.invalidate_filter())
        for action in ACTIONS:
            row = Gtk.ListBoxRow()
            row.action_name, row.search_text = action.name, self.action_label(action.name).lower()
            row.set_sensitive(self.action_enabled(action.name))
            binding = self.store.data.get("settings", {}).get("shortcuts", {}).get(action.name, action.shortcut)
            shortcut = Gtk.accelerator_get_label(*Gtk.accelerator_parse(binding)) if binding else ""
            row.add(Gtk.Label(label=self.action_label(action.name) + ("  ·  " + shortcut if shortcut else ""), xalign=0, margin=8))
            listing.add(row)
        selected = []
        def activate(_, row):
            selected.append(row.action_name)
            dialog.response(Gtk.ResponseType.OK)
        listing.connect("row-activated", activate)
        scroll = Gtk.ScrolledWindow()
        scroll.add(listing)
        dialog.get_content_area().pack_start(search, False, False, 8)
        dialog.get_content_area().pack_start(scroll, True, True, 0)
        dialog.show_all()
        search.grab_focus()
        dialog.run()
        dialog.destroy()
        if selected:
            self.run_action(selected[0])

    def action_lock(self):
        self.locked = True
        self.vault.lock()
        self.overlay.set_visible_child_name("locked")

    def unlock(self):
        try:
            self.vault.unlock()
        except Exception:
            result = self.fields_dialog("Private vault", [("password", "Password", "", "password")], "Unlock")
            if not result:
                return False
            try:
                self.vault.unlock(result["password"])
            except Exception as error:
                self.error(error)
                return False
        self.locked = False
        self.last_input = time.monotonic()
        self.overlay.set_visible_child_name("content")
        return True

    def apply_theme(self):
        theme = self.store.data.get("settings", {}).get("theme", "dark")
        settings = Gtk.Settings.get_default()
        settings.set_property("gtk-application-prefer-dark-theme", theme == "dark")
        effective_dark = theme == "dark" or (theme == "system" and "dark" in str(settings.get_property("gtk-theme-name")).lower())
        context = self.get_style_context()
        if effective_dark:
            context.add_class("uc-dark")
        else:
            context.remove_class("uc-dark")
        if not hasattr(self, "_appearance_provider"):
            path = Path(__file__).with_name("appearance.css")
            if path.is_file():
                provider = Gtk.CssProvider()
                provider.load_from_path(str(path))
                Gtk.StyleContext.add_provider_for_screen(self.get_screen(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
                self._appearance_provider = provider

    def apply_shortcuts(self):
        custom = self.store.data.get("settings", {}).get("shortcuts", {})
        for action in ACTIONS:
            binding = custom.get(action.name, action.shortcut)
            self.get_application().set_accels_for_action(f"win.{action.name}", [binding] if binding else [])

    def action_settings(self):
        settings = self.store.data.setdefault("settings", {})
        fields = [("theme", "Theme", settings.get("theme", "dark"), ["system", "light", "dark"]),
                  ("font", "Font", settings.get("font", "Monospace 11"), "text"),
                  ("autoLockMinutes", "Auto-lock minutes (0 = off)", settings.get("autoLockMinutes", 0), "text")]
        shortcuts = settings.get("shortcuts", {})
        for action in ACTIONS:
            fields.append(("shortcut:" + action.name, self.action_label(action.name), shortcuts.get(action.name, action.shortcut), "text"))
        result = self.fields_dialog("Settings", fields)
        if result:
            result["autoLockMinutes"] = max(0, int(result["autoLockMinutes"]))
            changed = {}
            for name in list(result):
                if name.startswith("shortcut:"):
                    binding = result.pop(name)
                    if binding and not Gtk.accelerator_parse(binding)[0]:
                        raise ValueError(self._("Invalid keyboard shortcut") + ": " + binding)
                    changed[name.removeprefix("shortcut:")] = binding
            result["shortcuts"] = changed
            result["locale"] = "es"
            settings.update(result)
            self.persist()
            self.apply_theme()
            self.apply_shortcuts()
            self.refresh_appearance()

    def action_import_config(self):
        path = self.choose_file("Import configuration")
        if not path:
            return
        importer = Importer(self.vault)
        try:
            preview = importer.preview(Path(path))
        except Exception:
            result = self.fields_dialog("Import configuration", [("password", "Password", "", "password"),
                                        ("connect", "Connection command", "", "password")])
            if not result:
                return
            preview = importer.preview(Path(path), passphrase=result["password"] or None, default_connect=result["connect"] or None)
        self.background(lambda: preview.preflight(self.store, self.import_remote_check),
                        lambda rows: self.show_import_preview(preview, rows))

    @staticmethod
    def import_remote_check(workspace, window, command):
        result = Transport(SSHCommand.parse(command), socket_name=window.get("tmuxSocket", "uniconnect")).preflight(window)
        return result["sessionExists"] and result["directoryExists"] and result["tmuxInstalled"]

    def show_import_preview(self, preview, rows):
        dialog = Gtk.Dialog(title=self._("Import preview"), transient_for=self, modal=True)
        dialog.add_buttons(self._("Cancel"), Gtk.ResponseType.CANCEL, self._("Import"), Gtk.ResponseType.OK)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=20)
        content.pack_start(Gtk.Label(label=self._("Select workspaces to import"), xalign=0), False, False, 0)
        checks = []
        for row in rows:
            check = Gtk.CheckButton(label=f'{row["name"]} · {self._(row["action"])} · {len(row["windows"])}')
            allowed = row["action"] not in ("conflict", "rejected")
            check.set_sensitive(allowed)
            check.set_active(allowed and row["action"] != "unchanged")
            checks.append((row["id"], check))
            content.pack_start(check, False, False, 0)
            notes = row.get("diagnostics", []) + [note for window in row["windows"] for note in window.get("diagnostics", [])]
            if notes:
                label = Gtk.Label(label="\n".join(self._(note) for note in dict.fromkeys(notes)), xalign=0)
                label.set_line_wrap(True)
                content.pack_start(label, False, False, 0)
        scroll = Gtk.ScrolledWindow()
        scroll.set_min_content_height(min(500, max(160, len(rows) * 65)))
        scroll.set_min_content_width(600)
        scroll.add(content)
        dialog.get_content_area().add(scroll)
        dialog.show_all()
        selected = [wid for wid, check in checks if check.get_active()] if dialog.run() == Gtk.ResponseType.OK else []
        dialog.destroy()
        if selected:
            chosen = preview.select_workspace_ids(selected)
            def apply(verified):
                if any(row["action"] in ("conflict", "rejected") for row in verified):
                    raise ValueError(self._("Import targets changed; preview again"))
                connections = {workspace["id"]: (chosen._commands.get(workspace.get("credentialId"))
                               or self.connection(workspace)) for workspace in chosen.workspaces
                               if workspace["kind"] == "ssh"}
                self.stage_runtime(chosen.workspaces, connections, lambda: chosen.apply(self.store),
                                   reason="runtime-import")
            self.background(lambda: chosen.preflight(self.store, self.import_remote_check), apply)

    def action_export_config(self):
        path = self.choose_file("Export configuration", save=True)
        if not path:
            return
        result = self.fields_dialog("Export configuration", [("password", "Password", "", "password"), ("confirm", "Confirm password", "", "password")], "Save")
        if result:
            if not result["password"] or result["password"] != result["confirm"]:
                raise ValueError(self._("Passwords do not match"))
            Importer(self.vault).export(self.store, Path(path), result["password"])

    def action_restore_backup(self):
        path = self.choose_file("Restore backup")
        if path:
            self.store.restore_backup(Path(path))
            self.reload_workspaces()

    def action_edit_ssh(self):
        workspace = self.current_workspace()
        if not workspace or workspace["kind"] != "ssh":
            return
        result = self.fields_dialog("Edit SSH connection", [("connect", "Connection command", self.connection(workspace), "password")])
        if not result:
            return
        parsed = SSHCommand.parse(result["connect"])
        proposed = copy.deepcopy(workspace)
        def check():
            for window in proposed["windows"]:
                transport = Transport(parsed, socket_name=window.get("tmuxSocket", "uniconnect"))
                result = transport.preflight(window)
                if not (result["sessionExists"] and result["directoryExists"] and result["tmuxInstalled"]):
                    raise ValueError(self._("The saved remote tmux session is unavailable") + " · " + window["name"])
        def apply(_):
            if self.store.workspace(workspace["id"]) is not workspace or workspace != proposed:
                raise ValueError("El espacio cambió durante la comprobación. Repite la operación.")
            def mutate():
                workspace["credentialId"] = self.vault.put(result["connect"])
                return workspace["credentialId"]
            self.stage_runtime([proposed], {workspace["id"]: result["connect"]}, mutate,
                               reason="runtime-endpoint-edit")
        self.background(check, apply)

    def action_upload(self):
        if self.focused_surface:
            path = self.choose_file("Upload file")
            if path:
                self.upload_paths([path], self.focused_surface)

    def paste_clipboard(self, surface):
        from .clipboard import ClipboardImages
        if not hasattr(self, "clipboard_images"):
            self.clipboard_images = ClipboardImages(self.store.root / "clipboard")
        def image_ready(path):
            if surface.workspace["kind"] == "local":
                self.clipboard_images.retain_for_local(path)
                self.upload_paths([str(path)], surface)
            else:
                self.upload_paths([str(path)], surface, cleanup=lambda: self.clipboard_images.release(path))
        self.clipboard_images.request(
            on_image=image_ready,
            on_text=lambda text: surface.terminal.paste_text(text), on_error=self.error)

    def upload_paths(self, paths, surface, cleanup=None):
        if surface.workspace["kind"] == "local":
            surface.send(" ".join(shlex.quote(p) for p in paths))
            return
        from .transfers import SFTPTransfer
        command = SSHCommand.parse(self.connection(surface.workspace))
        progress = Gtk.Dialog(title=self._("Upload file"), transient_for=self)
        progress.add_button(self._("Cancel"), Gtk.ResponseType.CANCEL)
        bar = Gtk.ProgressBar(margin=20, show_text=True)
        progress.get_content_area().add(bar)
        transfer = SFTPTransfer(command)
        progress.connect("response", lambda *_: transfer.cancel())
        progress.show_all()
        def report(done, total):
            def show():
                bar.set_fraction(done / total if total else 0)
                bar.set_text(f"{done / total:.0%}" if total else "0%")
                return False
            GLib.idle_add(show)
        def work():
            uploaded = []
            try:
                for path in paths:
                    uploaded.append(transfer.run(path, surface.record.get("cwd") or surface.workspace.get("cwd") or ".", progress=report))
            except Exception:
                GLib.idle_add(progress.destroy)
                raise
            finally:
                if cleanup:
                    cleanup()
            return uploaded
        def done(result):
            progress.destroy()
            surface.send(" ".join(shlex.quote(p) for p in result))
        self.background(work, done)

    def action_kill_tmux(self):
        surface = self.focused_surface
        if not surface or surface.workspace["kind"] != "ssh":
            return
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.WARNING,
                                   buttons=Gtk.ButtonsType.NONE, text=self._("Terminate remote tmux session"))
        dialog.add_buttons(self._("Cancel"), Gtk.ResponseType.CANCEL, self._("Apply"), Gtk.ResponseType.OK)
        dialog.format_secondary_text(surface.record.get("tmux", "") + "\n" + self._("This stops the remote process. The saved window remains recoverable."))
        confirmed = dialog.run() == Gtk.ResponseType.OK
        dialog.destroy()
        if confirmed:
            command = SSHCommand.parse(self.connection(surface.workspace))
            remote = shlex.join(["tmux", "-L", surface.record.get("tmuxSocket", "uniconnect"), "kill-session", "-t", "=" + surface.record["tmux"]])
            self.background(lambda: subprocess.run(command.argv(remote, batch=True), env={**os.environ, **command.environment()}, capture_output=True, check=True, timeout=20))

    def action_help(self):
        path = Path(__file__).resolve().parents[1] / "README.md"
        Gio.AppInfo.launch_default_for_uri(path.as_uri(), None)

    def action_quit(self):
        self.close()

    def on_delete(self, *_):
        if self._closed:
            return False
        self._closed = True
        if self._runtime_operation and self._runtime_operation.active:
            self._runtime_operation.cancel()
        if self._sidebar_refresh:
            GLib.source_remove(self._sidebar_refresh)
            self._sidebar_refresh = 0
        if self._tick_source:
            GLib.source_remove(self._tick_source)
            self._tick_source = 0
        self.persist()
        if hasattr(self, "mobile"):
            self.mobile.close()
        if hasattr(self, "_appearance_provider"):
            Gtk.StyleContext.remove_provider_for_screen(self.get_screen(), self._appearance_provider)
        for surface in self.surfaces.values():
            surface.dispose()
        if hasattr(self, "clipboard_images"):
            self.clipboard_images.close()
        self.pool.shutdown(wait=False, cancel_futures=True)
        self.get_application().quit()
        return False
