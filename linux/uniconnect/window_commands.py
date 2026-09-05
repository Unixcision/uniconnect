"""Shared GTK window actions; menu, palette and shortcuts use identical context."""

from pathlib import Path

from gi.repository import Gdk, Gio, Gtk


class WindowCommands:
    def action_label(self, name):
        workspace, surface = self.current_workspace(), self.focused_surface
        if name == "pin_workspace" and workspace and workspace.get("pinned"):
            return self._("Unpin workspace")
        if name == "pin_window" and surface and surface.record.get("pinned"):
            return self._("Unpin window")
        if name == "maximize_pane" and workspace and workspace.get("maximizedPaneId"):
            return self._("Restore pane")
        for prefix, label in (("workspace_", "Workspace {number}"), ("window_", "Window {number}")):
            if name.startswith(prefix) and name[len(prefix):].isdigit():
                return self._(label).format(number=name[len(prefix):])
        return self._(self.action_map[name].label)

    def action_enabled(self, name):
        if self.locked:
            return name in ("lock", "quit")
        workspace, surface = self.current_workspace(), self.focused_surface
        windows = workspace.get("windows", []) if workspace else []
        for prefix, values in (("workspace_", self.store.workspaces), ("window_", windows)):
            if name.startswith(prefix) and name[len(prefix):].isdigit():
                index = int(name[len(prefix):])
                return bool(values) if index == 9 else len(values) >= index
        if name in ("new_window", "close_workspace", "rename_workspace", "pin_workspace", "split_right", "split_down"):
            return workspace is not None
        if name in ("reopen", "reopen_last"):
            return bool(self.store.closed)
        if name == "edit_ssh":
            return bool(workspace and workspace["kind"] == "ssh")
        if name in ("reconnect", "kill_tmux"):
            return bool(surface and surface.workspace["kind"] == "ssh" and surface.record.get("tmux"))
        if name == "reconnect_all":
            return any(w["kind"] == "ssh" and w["windows"] for w in self.store.workspaces)
        if name == "copy" or name == "find_selection":
            return bool(surface and surface.terminal.get_has_selection())
        if name == "hide_find":
            return bool(surface and surface.search.get_search_mode())
        if name == "reset_window_name":
            return bool(surface and surface.record.get("originalName"))
        if name in ("close_other_windows", "close_left_windows", "close_right_windows"):
            return bool(self.close_candidates(name))
        if name.startswith("workspace_") and name in ("workspace_up", "workspace_down", "workspace_first"):
            if not workspace:
                return False
            index = self.store.workspaces.index(workspace)
            return index < len(self.store.workspaces) - 1 if name == "workspace_down" else index > 0
        if name in ("workspace_previous", "workspace_next"):
            return len(self.store.workspaces) > 1
        if name in ("window_previous", "window_next"):
            return len(windows) > 1
        if name in ("equalize_panes", "maximize_pane", "focus_left", "focus_right", "focus_up", "focus_down",
                    "move_window_left", "move_window_right"):
            return bool(surface and len(self.pane_notebooks()) > 1)
        if name in ("close_window", "rename_window", "pin_window", "paste", "find", "find_next", "find_previous",
                    "send_ctrl_f", "upload", "font_larger", "font_smaller", "font_reset"):
            return surface is not None
        return True

    def refresh_actions(self):
        for name in self.action_map:
            action = self.lookup_action(name)
            action.set_enabled(self.action_enabled(name))
        for name, widget in getattr(self, "menu_items", []):
            widget.set_label(self.action_label(name))
            widget.set_sensitive(self.action_enabled(name))

    def select_surface(self, surface):
        self.select_workspace(surface.workspace["id"])
        parent = surface.get_parent()
        parent.set_current_page(parent.page_num(surface))
        self.focused_surface = surface
        surface.workspace["selectedWindowId"] = surface.record["id"]
        surface.terminal.grab_focus()
        self.persist()
        self.refresh_actions()

    def select_number(self, kind, number):
        values = self.store.workspaces if kind == "workspace" else self.current_workspace()["windows"]
        if not values or (number != 9 and number > len(values)):
            return
        target = values[-1 if number == 9 else number - 1]
        if kind == "workspace":
            self.select_workspace(target["id"])
        elif target["id"] in self.surfaces:
            self.select_surface(self.surfaces[target["id"]])

    def cycle_workspace(self, delta):
        values = self.store.workspaces
        current = self.current_workspace()
        if current and values:
            self.select_workspace(values[(values.index(current) + delta) % len(values)]["id"])

    def cycle_window(self, delta):
        workspace, surface = self.current_workspace(), self.focused_surface
        if workspace and surface:
            values = workspace["windows"]
            target = values[(values.index(surface.record) + delta) % len(values)]
            self.select_surface(self.surfaces[target["id"]])

    def action_workspace_previous(self):
        self.cycle_workspace(-1)

    def action_workspace_next(self):
        self.cycle_workspace(1)

    def action_window_previous(self):
        self.cycle_window(-1)

    def action_window_next(self):
        self.cycle_window(1)

    def move_workspace(self, destination):
        workspace = self.current_workspace()
        items = self.store.workspaces
        if not workspace:
            return
        original = list(items)
        items.remove(workspace)
        items.insert(max(0, min(destination, len(items))), workspace)
        try:
            self.store.save()
        except Exception:
            items[:] = original
            raise
        self.refresh_sidebar()

    def action_workspace_up(self):
        self.move_workspace(self.store.workspaces.index(self.current_workspace()) - 1)

    def action_workspace_down(self):
        self.move_workspace(self.store.workspaces.index(self.current_workspace()) + 1)

    def action_workspace_first(self):
        self.move_workspace(0)

    def toggle_pin(self, record):
        previous = record.get("pinned", False)
        record["pinned"] = not previous
        try:
            self.store.save()
        except Exception:
            record["pinned"] = previous
            raise
        self.refresh_sidebar()
        workspace = self.current_workspace()
        self.build_workspace(workspace)
        self.select_workspace(workspace["id"])

    def action_pin_workspace(self):
        self.toggle_pin(self.current_workspace())

    def action_pin_window(self):
        self.toggle_pin(self.focused_surface.record)

    def action_reset_window_name(self):
        record = self.focused_surface.record
        record["name"] = record.pop("originalName", record["name"])
        self.persist()
        self.build_workspace(self.current_workspace())
        self.select_workspace(self.current_workspace()["id"])

    def close_candidates(self, name):
        surface = self.focused_surface
        if not surface:
            return []
        windows = [w for w in surface.workspace["windows"] if w.get("paneId", "main") == surface.record.get("paneId", "main")]
        index = windows.index(surface.record)
        values = windows[:index] if name == "close_left_windows" else windows[index + 1:] if name == "close_right_windows" else windows[:index] + windows[index + 1:]
        return [w for w in values if not w.get("pinned")]

    def close_window_group(self, name):
        records = self.close_candidates(name)
        if not records or not self.confirm("Close selected windows?", "\n".join(w["name"] for w in records)):
            return
        focused = self.focused_surface
        for record in records:
            self.close_surface(self.surfaces[record["id"]])
        self.select_surface(focused)

    def action_close_other_windows(self):
        self.close_window_group("close_other_windows")

    def action_close_left_windows(self):
        self.close_window_group("close_left_windows")

    def action_close_right_windows(self):
        self.close_window_group("close_right_windows")

    def confirm(self, title, detail):
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.OK_CANCEL, text=self._(title))
        dialog.format_secondary_text(detail)
        accepted = dialog.run() == Gtk.ResponseType.OK
        dialog.destroy()
        return accepted

    def action_reopen_last(self):
        if self.store.closed:
            self.store.restore_closed(self.store.closed[0]["id"])
            self.reload_workspaces()

    def action_find_next(self):
        self.focused_surface.terminal.search_find_next()

    def action_find_previous(self):
        self.focused_surface.terminal.search_find_previous()

    def action_hide_find(self):
        self.focused_surface.search.set_search_mode(False)
        self.focused_surface.terminal.grab_focus()

    def action_find_selection(self):
        # X11 primary selection is populated by VTE selecting text; unlike Copy,
        # reading it does not overwrite the user's normal clipboard.
        surface = self.focused_surface
        def selected(_, text, data):
            if text and not surface.disposed:
                surface.search_entry.set_text(text)
                surface.show_find()
        Gtk.Clipboard.get(Gdk.SELECTION_PRIMARY).request_text(selected, None)

    def action_send_ctrl_f(self):
        self.focused_surface.send("\x06")

    def pane_notebooks(self):
        workspace = self.current_workspace()
        return [notebook for (wid, _), notebook in self.notebooks.items() if workspace and wid == workspace["id"]]

    def action_equalize_panes(self):
        def equalize(widget):
            if isinstance(widget, Gtk.Paned):
                size = widget.get_allocated_width() if widget.get_orientation() == Gtk.Orientation.HORIZONTAL else widget.get_allocated_height()
                widget.set_position(size // 2)
            if isinstance(widget, Gtk.Container):
                for child in widget.get_children():
                    equalize(child)
        workspace = self.current_workspace()
        if workspace:
            equalize(self.pages[workspace["id"]])
            self.persist()

    def apply_pane_visibility(self, workspace):
        selected = workspace.get("maximizedPaneId")
        for (wid, pane), notebook in self.notebooks.items():
            if wid == workspace["id"]:
                notebook.set_visible(not selected or pane == selected)

    def action_maximize_pane(self):
        workspace = self.current_workspace()
        if workspace.get("maximizedPaneId"):
            workspace.pop("maximizedPaneId")
        else:
            workspace["maximizedPaneId"] = self.focused_surface.record.get("paneId", "main")
        self.apply_pane_visibility(workspace)
        self.persist()
        self.refresh_actions()

    def adjacent_pane(self, direction, move=False):
        surface = self.focused_surface
        notebooks = self.pane_notebooks()
        current = surface.get_parent()
        horizontal = surface.workspace.get("splitAxis", "horizontal") == "horizontal"
        if direction in ("up", "down") and horizontal or direction in ("left", "right") and not horizontal:
            return
        delta = -1 if direction in ("left", "up") else 1
        index = notebooks.index(current) + delta
        if index < 0 or index >= len(notebooks):
            return
        target = notebooks[index]
        if move:
            pane_id = next(pane for (wid, pane), notebook in self.notebooks.items() if notebook is target)
            surface.record["paneId"] = pane_id
            self.persist()
            self.build_workspace(surface.workspace)
            self.select_surface(surface)
        else:
            self.select_surface(target.get_nth_page(target.get_current_page()))

    def action_focus_left(self):
        self.adjacent_pane("left")

    def action_focus_right(self):
        self.adjacent_pane("right")

    def action_focus_up(self):
        self.adjacent_pane("up")

    def action_focus_down(self):
        self.adjacent_pane("down")

    def action_move_window_left(self):
        self.adjacent_pane("left" if self.current_workspace().get("splitAxis", "horizontal") == "horizontal" else "up", move=True)

    def action_move_window_right(self):
        self.adjacent_pane("right" if self.current_workspace().get("splitAxis", "horizontal") == "horizontal" else "down", move=True)

    def action_about(self):
        dialog = Gtk.AboutDialog(transient_for=self, modal=True, program_name="UniConnect",
                                 version=self._("Linux development"), website="https://github.com/Unixcision/UniConnect",
                                 comments=self._("Durable local and SSH workspaces"))
        dialog.run()
        dialog.destroy()

    def action_help_shortcuts(self):
        path = Path(__file__).resolve().parents[2] / "docs/MENUS.md"
        Gio.AppInfo.launch_default_for_uri(path.as_uri(), None)

    def action_help_settings(self):
        self.action_settings()

    def action_report_issue(self):
        Gio.AppInfo.launch_default_for_uri("https://github.com/Unixcision/UniConnect/issues", None)
