"""Native VTE surface; terminating the frontend only detaches its tmux client."""

import os
import signal
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import unquote, urlparse

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("Vte", "2.91")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango, Vte

from .transport import SSHCommand, Transport, TransportError, terminal_launch


class TerminalSurface(Gtk.Box):
    def __init__(self, owner, workspace, window, create=False, *, clock=time.monotonic,
                 schedule=None, cancel_timer=None, launch_preparer=None, auto_launch=True):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.owner, self.workspace, self.record = owner, workspace, window
        self.pid, self.generation, self.disposed = 0, 0, False
        self._pending_launch = None
        self._preparing = False
        self._spawning = False
        self._ownership_keys = []
        self._lifecycle_observers = []
        self._exit_during_spawn = None
        self._launch_notice = None
        self._launch_crash_markers = 0
        self._clock = clock
        self._schedule = schedule or (lambda delay, callback: GLib.timeout_add(max(1, int(delay * 1000)), callback))
        self._cancel_timer = cancel_timer or GLib.source_remove
        self._launch_preparer = launch_preparer or self._build_launch
        self._retry_source = None
        self._stable_source = None
        self._outage_started = None
        self._retry_attempts = 0
        self._allow_auto_retry = False
        self.status = "Connecting"
        self.terminal = Vte.Terminal()
        self.terminal.set_scrollback_lines(50000)
        self.terminal.set_mouse_autohide(True)
        self.terminal.set_allow_hyperlink(True)
        self.terminal.set_scroll_on_output(False)
        self.terminal.set_scroll_on_keystroke(True)
        self.terminal.set_audible_bell(False)
        self.apply_appearance()
        self.terminal.connect("child-exited", self.on_exit)
        self.terminal.connect("bell", lambda *_: self.owner.notify_window(self.workspace, self.record))
        self.terminal.connect("focus-in-event", self.on_focus)
        self.terminal.connect("button-press-event", self.on_button)
        self.terminal.connect("notify::current-directory-uri", self.on_directory)
        self.terminal.drag_dest_set(Gtk.DestDefaults.ALL, [], Gdk.DragAction.COPY)
        self.terminal.drag_dest_add_uri_targets()
        self.terminal.connect("drag-data-received", self.on_drop)
        self.search = Gtk.SearchBar()
        self.search_entry = Gtk.SearchEntry()
        self.search_entry.set_placeholder_text(self.owner._("Find"))
        self.search_entry.connect("search-changed", self.find)
        self.search_entry.connect("activate", lambda *_: self.terminal.search_find_next())
        self.search.connect_entry(self.search_entry)
        self.search.add(self.search_entry)
        self.pack_start(self.search, False, False, 0)
        scroll = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        scroll.pack_start(self.terminal, True, True, 0)
        scroll.pack_start(Gtk.Scrollbar(orientation=Gtk.Orientation.VERTICAL,
                                       adjustment=self.terminal.get_vadjustment()), False, False, 0)
        self.pack_start(scroll, True, True, 0)
        self.footer = Gtk.Box(spacing=8, margin_start=10, margin_end=8, margin_top=3, margin_bottom=3)
        self.status_label = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.MIDDLE)
        self.footer.pack_start(self.status_label, True, True, 0)
        self.retry = Gtk.Button.new_from_icon_name("view-refresh-symbolic", Gtk.IconSize.MENU)
        self.retry.set_relief(Gtk.ReliefStyle.NONE)
        self.retry.set_tooltip_text(self.owner._("Reconnect"))
        self.retry.connect("clicked", lambda *_: self.launch())
        self.footer.pack_end(self.retry, False, False, 0)
        self.pack_end(self.footer, False, False, 0)
        self.show_all()
        if auto_launch:
            GLib.idle_add(self.launch, create)

    def subscribe_lifecycle(self, callback):
        """Observe actual child events; spawning alone never proves attachment."""
        self._lifecycle_observers.append(callback)
        def unsubscribe():
            if callback in self._lifecycle_observers:
                self._lifecycle_observers.remove(callback)
        return unsubscribe

    def _emit_lifecycle(self, kind, **details):
        event = {"kind": kind, "generation": self.generation, "pid": self.pid, **details}
        for callback in tuple(self._lifecycle_observers):
            callback(event)

    def apply_appearance(self):
        settings = self.owner.store.data.get("settings", {})
        self.terminal.set_font(Pango.FontDescription(settings.get("font", "Monospace 11")))
        self.terminal.set_font_scale(self.owner.font_scale)
        dark = settings.get("theme", "dark") != "light"
        fg, bg = Gdk.RGBA(), Gdk.RGBA()
        fg.parse("#dce2ed" if dark else "#20242d")
        bg.parse("#11151c" if dark else "#ffffff")
        self.terminal.set_colors(fg, bg, [])

    def update_status(self, status, detail=""):
        self.status = status
        self.record["status"] = status.lower()
        suffix = self.owner._(detail) if detail else self.record.get("repo") or self.record.get("cwd") or self.workspace.get("cwd", "")
        self.status_label.set_text(f'{self.owner._(status)}  ·  {suffix}')
        self.owner.refresh_sidebar()

    def launch(self, create=False):
        """An explicit reconnect starts a new bounded recovery budget."""
        self._cancel_reconnect(reset=True)
        return self._queue_launch(create)

    def _queue_launch(self, create=False):
        if self.disposed:
            return False
        self._allow_auto_retry = True
        self.generation += 1
        self._pending_launch = (self.generation, create)
        self.update_status("Connecting")
        if self.pid:
            self.signal_client(self.pid)
        elif not self._spawning and not self._preparing:
            self._prepare_launch()
        return False

    def _prepare_launch(self):
        if self.disposed or self._pending_launch is None or self.pid or self._spawning or self._preparing:
            return False
        generation, create = self._pending_launch
        self._pending_launch = None
        self._preparing = True
        try:
            connect = self.owner.connection(self.workspace) if self.workspace["kind"] == "ssh" else None
            workspace, record = dict(self.workspace), dict(self.record)
        except Exception as error:
            self._preparing = False
            self.update_status("Disconnected", str(error))
            self._emit_lifecycle("failed", reason="connection-unavailable")
            return False

        def prepare():
            try:
                launch, keys = self._launch_preparer(workspace, record, connect, create)
                GLib.idle_add(self._prepared, generation, launch, keys, None)
            except Exception as error:
                GLib.idle_add(self._prepared, generation, None, [], error)

        threading.Thread(target=prepare, name="uniconnect-launch", daemon=True).start()
        return False

    @staticmethod
    def _build_launch(workspace, record, connect, create):
        command = SSHCommand.parse(connect) if connect else None
        socket_name = record.get("tmuxSocket") or ("uniconnect" if command else "uniconnect-local")
        record["tmuxSocket"] = socket_name
        record["cwd"] = record.get("cwd") or workspace.get("cwd") or str(Path.home())
        if command is None and not Path(record["cwd"]).is_dir():
            return terminal_launch(workspace, record, create=False), []
        endpoint = command.endpoint_key() if command else ("local",)
        keys = [("tmux", endpoint, socket_name, record["tmux"])] if record.get("tmux") else []
        if record.get("sessionId"):
            session = record["sessionId"]
            try:
                session = str(uuid.UUID(session))
            except ValueError:
                pass
            keys.append(("agent", endpoint, record.get("agent"), session))
        if create and record.get("tmux"):
            Transport(command, socket_name=socket_name).ensure_session(record)
        return terminal_launch(workspace, record, connect_command=command, create=False), keys

    def _prepared(self, generation, launch, keys, error):
        self._preparing = False
        if self.disposed:
            return False
        if generation != self.generation:
            return self._prepare_launch()
        if error:
            self._cancel_reconnect(reset=True)
            self._release_ownership()
            self.update_status("Disconnected", str(error))
            self._emit_lifecycle("failed", reason="launch-unavailable")
            return False
        registry = getattr(self.owner, "_terminal_owners", None)
        if registry is None:
            registry = self.owner._terminal_owners = {}
        if any(registry.get(key) not in (None, self) for key in keys):
            self._cancel_reconnect(reset=True)
            self._release_ownership()
            self.update_status("Disconnected", self.owner._("This session is already open in another window"))
            self._emit_lifecycle("failed", reason="duplicate-owner")
            return False
        self._release_ownership()
        self._ownership_keys = keys
        self._launch_notice = launch.notice
        if launch.notice:
            self.record["missingRoot"] = launch.notice
            self.record["runtimeState"] = "shell"
        else:
            self.record.pop("missingRoot", None)
        for key in keys:
            registry[key] = self
        try:
            # The transport already removes unsafe ambient SSH variables. Merging
            # os.environ here would restore precisely the entries it scrubbed.
            env = dict(launch.env or {})
            env.update(TERM="xterm-256color", COLORTERM="truecolor", UNICONNECT_WINDOW_ID=self.record["id"])
            # Do not propagate the parent coding agent's pane/session ownership into a child.
            for key in ("TMUX", "TMUX_PANE", "CODEX_THREAD_ID", "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID"):
                env.pop(key, None)
            self._spawning = True
            self._exit_during_spawn = None
            self._launch_crash_markers = self._server_crash_marker_count()
            # PyGObject exposes child_setup_data even though VTE's generated docstring
            # omits it. Keep its explicit None before the timeout argument.
            self.terminal.spawn_async(
                Vte.PtyFlags.DEFAULT, launch.cwd, launch.argv,
                [f"{k}={v}" for k, v in env.items()],
                GLib.SpawnFlags(Vte.SPAWN_NO_PARENT_ENVV), None, None,
                -1, None, self.on_spawn, generation,
            )
        except Exception as error:
            self._spawning = False
            self._release_ownership()
            self.update_status("Disconnected", str(error))
            self._emit_lifecycle("failed", reason="spawn-unavailable")
        return False

    def on_spawn(self, terminal, pid, error, generation):
        self._spawning = False
        early_exit = self._exit_during_spawn
        already_exited = early_exit is not None
        self._exit_during_spawn = None
        if generation != self.generation or self.disposed:
            if pid > 0 and not already_exited:
                self.pid = pid
                self.signal_client(pid)
            else:
                self._release_ownership()
                GLib.idle_add(self._prepare_launch)
            return
        if error:
            self._release_ownership()
            self.update_status("Disconnected", str(error))
            self._emit_lifecycle("failed", reason="spawn-unavailable")
        elif already_exited:
            self.on_exit(terminal, early_exit)
        else:
            self.pid = pid
            self.update_status("Folder missing" if self._launch_notice else "Running", self._launch_notice or "")
            self._emit_lifecycle("spawned")
            self._watch_stability(generation, pid)
            self.owner.persist()

    def on_exit(self, terminal, status):
        if self._spawning:
            self._exit_during_spawn = status
            return
        previous_pid = self.pid
        self.pid = 0
        self._emit_lifecycle("exited", pid=previous_pid, status=os.waitstatus_to_exitcode(status))
        self._clear_timer("_stable_source")
        if self.disposed:
            self._release_ownership()
            return
        if self.workspace["kind"] == "local":
            self.record["runtimeState"] = "stopped"
        if self._pending_launch is not None:
            # Do not start another VTE child until the old child's exit signal has
            # been consumed: child-exited carries no PID/generation identifier.
            GLib.idle_add(self._prepare_launch)
            return
        code = os.waitstatus_to_exitcode(status)
        transient = code == 255 or (code == 1 and self._server_crash_marker_count() > self._launch_crash_markers)
        if self._allow_auto_retry and self.workspace["kind"] == "ssh" and transient:
            if self._schedule_retry():
                self.owner.persist()
                return
            detail = self.owner._("Reconnect attempts exhausted")
        else:
            detail = self.owner._("Exit {code}").format(code=code)
            self._cancel_reconnect(reset=True)
        self._release_ownership()
        self.update_status("Disconnected", detail)
        self.owner.persist()

    def _server_crash_marker_count(self):
        # tmux reports this outside its alternate screen on an unexpected server
        # death. An old scrollback marker cannot make a later generic exit 1 retry.
        if hasattr(self.terminal, "get_text_format"):
            text = self.terminal.get_text_format(Vte.Format.TEXT) or ""
        else:
            text = self.terminal.get_text(None, None)[0] or ""
        return sum(line.strip() in ("server exited unexpectedly", "[server exited unexpectedly]")
                   for line in text.splitlines())

    def _clear_timer(self, attribute):
        source = getattr(self, attribute)
        if source is not None:
            self._cancel_timer(source)
            setattr(self, attribute, None)

    def _cancel_reconnect(self, *, reset):
        self._clear_timer("_retry_source")
        self._clear_timer("_stable_source")
        if reset:
            self._outage_started = None
            self._retry_attempts = 0

    def _schedule_retry(self):
        """Keep ownership during bounded SSH transport/server-crash recovery."""
        if self._outage_started is None:
            self._outage_started = self._clock()
        elapsed = self._clock() - self._outage_started
        delay = min(2 ** self._retry_attempts, 16)
        if self._retry_attempts >= 6 or elapsed + delay >= 60:
            return False
        generation = self.generation

        def retry():
            if self.disposed or generation != self.generation or self.pid or self._pending_launch is not None:
                return False
            self._retry_source = None
            if self._clock() - self._outage_started >= 60:
                self._release_ownership()
                self.update_status("Disconnected", self.owner._("Reconnect attempts exhausted"))
                self.owner.persist()
                return False
            self._retry_attempts += 1
            # A retry can only attach to the exact persisted tmux. It never creates.
            self._queue_launch(False)
            return False

        self._retry_source = self._schedule(delay, retry)
        self.update_status("Reconnecting", f"{self._retry_attempts + 1}/6 · {delay}s")
        return True

    def _watch_stability(self, generation, pid):
        if self.workspace["kind"] != "ssh" or self._outage_started is None:
            return

        def stable():
            if not self.disposed and generation == self.generation and self.pid == pid:
                self._stable_source = None
                self._outage_started = None
                self._retry_attempts = 0
            return False

        # Spawn success only proves that the local ssh process exists. Requiring a
        # full minute alive prevents ConnectTimeout failures from resetting budget.
        self._stable_source = self._schedule(60, stable)

    def _release_ownership(self):
        registry = getattr(self.owner, "_terminal_owners", {})
        for key in self._ownership_keys:
            if registry.get(key) is self:
                del registry[key]
        self._ownership_keys = []

    @staticmethod
    def signal_client(pid):
        try:
            group = os.getpgid(pid)
            if group == pid:
                os.killpg(group, signal.SIGHUP)
            else:
                os.kill(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass

    def stop_client(self):
        self._allow_auto_retry = False
        self._cancel_reconnect(reset=True)
        self.generation += 1
        self._pending_launch = None
        if self.pid:
            self.signal_client(self.pid)
        elif not self._spawning:
            self._release_ownership()

    def dispose(self):
        self.disposed = True
        self.stop_client()

    def on_focus(self, *_):
        if getattr(self.owner, "_building_workspace", 0):
            return False
        self.owner.focused_surface = self
        self.workspace["selectedWindowId"] = self.record["id"]
        self.record["unread"] = False
        self.owner.refresh_sidebar()
        return False

    def on_directory(self, *_):
        if self.disposed:
            return
        uri = self.terminal.get_current_directory_uri()
        if uri and self.workspace["kind"] == "local":
            path = unquote(urlparse(uri).path)
            if Path(path).is_dir():
                self.record["cwd"] = path
                self.owner.persist()

    def on_button(self, _, event):
        if event.button == 3:
            self.on_focus()
            self.owner.context_menu(["copy", "paste", "find", "new_window", "rename_window",
                                     "split_right", "split_down", "reconnect", "upload", "close_window"], event)
            return True
        return False

    def on_drop(self, widget, context, x, y, data, info, timestamp):
        paths = [unquote(urlparse(uri).path) for uri in (data.get_uris() or []) if urlparse(uri).scheme == "file"]
        if paths:
            self.owner.upload_paths(paths, self)
        Gtk.drag_finish(context, bool(paths), False, timestamp)

    def show_find(self):
        self.search.set_search_mode(True)
        self.search_entry.grab_focus()

    def find(self, *_):
        import re
        query = self.search_entry.get_text()
        try:
            regex = Vte.Regex.new_for_search(re.escape(query), -1, 0x00080000) if query else None
            self.terminal.search_set_regex(regex, 0)
            self.terminal.search_set_wrap_around(True)
            self.terminal.search_find_previous()
        except GLib.Error:
            pass

    def send(self, text):
        self.terminal.feed_child(text.encode())

    def copy(self):
        self.terminal.copy_clipboard_format(Vte.Format.TEXT)

    def paste(self):
        if hasattr(self.owner, "paste_clipboard"):
            self.owner.paste_clipboard(self)
        else:
            self.terminal.paste_clipboard()
