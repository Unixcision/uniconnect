"""Mobile actions over the authoritative desktop model and its existing panes."""

import base64
import datetime
import hashlib
import json
import shlex
import socket
import threading
import time
import uuid
from collections import OrderedDict
from concurrent.futures import Future, TimeoutError

from .mobile_protocol import RPCError
from .mobile_render_grid import MAX_SCROLLBACK_ROWS, capture_dependencies_ready, render_grid_from_tmux_capture
from .transport import SSHCommand, Transport


class MobileRPC:
    def __init__(self, window, access, schedule, *, transport_factory=Transport,
                 clock=time.monotonic, wait=time.sleep):
        self.window, self.access, self.schedule = window, access, schedule
        self.transport_factory = transport_factory
        self.clock, self.wait = clock, wait
        self.host = None
        self.viewports, self.original_sizes = {}, {}
        self.revisions = {}
        self.revision_lock = threading.Lock()
        # Serialize capture AND revision assignment for a pane, including across
        # devices. A fixed number of locks bounds memory without retaining IDs.
        self.capture_locks = tuple(threading.Lock() for _ in range(16))
        self.capture_cache = OrderedDict()
        self.capture_versions, self.capture_started = {}, {}

    def on_main(self, action):
        future = Future()
        def deliver():
            if not future.set_running_or_notify_cancel():
                return False
            try:
                future.set_result(action())
            except Exception as error:
                future.set_exception(error)
            return False
        self.schedule(deliver)
        try:
            return future.result(timeout=5)
        except TimeoutError as error:
            future.cancel()  # Expired queued work must not execute a late mutation.
            raise RPCError("busy", "El escritorio está ocupado; vuelve a intentarlo") from error

    def dispatch(self, method, params, connection_id, *, authorized=lambda: True):
        def checked(action):
            if not authorized():
                raise RPCError("approval_required", "El permiso de este dispositivo ha sido revocado")
            return action()
        if method == "mobile.host.status":
            ready = capture_dependencies_ready()
            capabilities = ["events.v1", "terminal.viewport.v1", "notifications.v1"]
            if ready:
                capabilities += ["terminal.replay.v1", "terminal.render_grid.v1"]
            return {"machine_id": self.access.machine_id, "display_name": socket.gethostname(), "platform": "linux",
                    "terminal_fidelity": "render_grid" if ready else "unavailable",
                    "capabilities": capabilities,
                    "routes": [{"id": "tailscale", "kind": "tailscale", "priority": 0,
                                "endpoint": {"type": "host_port", "host": self.host.address, "port": self.host.port}}]}
        operation = method.removeprefix("mobile.")
        if operation == "terminal.replay":
            return self.replay(params, authorized=authorized)
        return self.on_main(lambda: checked(lambda: self._dispatch_main(operation, params, connection_id)))

    def _dispatch_main(self, operation, params, connection_id):
        if self.window.locked:
            raise RPCError("locked", "UniConnect está bloqueado")
        operation_in_progress = getattr(self.window, "_runtime_operation", None)
        if operation in ("workspace.create", "terminal.create", "terminal.reconnect", "terminal.reset") and (
                operation_in_progress and operation_in_progress.active):
            raise RPCError("busy", "Hay una conexión en preparación; espera a que termine")
        if operation == "workspace.list":
            return self.workspace_list(params)
        if operation == "notifications.list":
            return self.notifications(params)
        if operation == "workspace.create":
            workspace = self.window.create_mobile_workspace(params)
            return {**self.workspace_list({"workspace_id": workspace["id"]}), "created_workspace_id": workspace["id"]}
        if operation == "terminal.create":
            workspace, _, _ = self.target(params, terminal=False)
            record = self.window.create_mobile_window(workspace, params)
            return {**self.workspace_list({"workspace_id": workspace["id"]}), "created_terminal_id": record["id"]}
        workspace, record, surface = self.target(params)
        attached = False
        if operation in ("terminal.reconnect", "terminal.reset") and surface is None:
            attach = getattr(self.window, "ensure_mobile_surface", None)
            if attach is not None:
                surface = attach(workspace, record)
                attached = True
        if surface is None or surface.disposed:
            raise RPCError("surface_unavailable", "Esta terminal no está abierta en el escritorio")
        identifiers = {"workspace_id": workspace["id"], "surface_id": record["id"]}
        if operation == "terminal.input":
            text = params.get("text")
            if not isinstance(text, str) or len(text.encode()) > 65536:
                raise RPCError("invalid_params", "La entrada de terminal no es válida")
            if not surface.pid:
                raise RPCError("process_exited", "La terminal está desconectada")
            surface.send(text)
            return {**identifiers, "queued": True}
        if operation in ("terminal.reconnect", "terminal.reset"):
            if not record.get("tmux"):
                raise RPCError("not_durable", "Esta consola antigua no tiene una sesión tmux recuperable")
            if not attached:
                surface.launch()
            return {**identifiers, "queued": True}
        if operation == "terminal.viewport":
            return {**identifiers, **self.viewport(surface, params, connection_id)}
        if operation == "terminal.scroll":
            lines = params.get("delta_y", params.get("lines", 0))
            if not isinstance(lines, (int, float)) or not -1000 <= lines <= 1000:
                raise RPCError("invalid_params", "Desplazamiento no válido")
            adjustment = surface.terminal.get_vadjustment()
            adjustment.set_value(max(adjustment.get_lower(), min(adjustment.get_value() + lines,
                                                                 adjustment.get_upper() - adjustment.get_page_size())))
            return {**identifiers, "queued": True}
        raise RPCError("method_not_found", "Esta operación no está disponible")

    def target(self, params, *, terminal=True):
        workspace_id = params.get("workspace_id")
        if not isinstance(workspace_id, str) or not workspace_id:
            raise RPCError("invalid_params", "Indica el espacio de trabajo explícitamente")
        workspace = next((value for value in self.window.store.workspaces if value["id"] == workspace_id), None)
        if workspace is None:
            raise RPCError("not_found", "No se encontró el espacio de trabajo")
        if not terminal:
            return workspace, None, None
        ids = [params[key] for key in ("surface_id", "terminal_id", "tab_id") if params.get(key) is not None]
        if not ids or not all(isinstance(value, str) and value and value == ids[0] for value in ids):
            raise RPCError("invalid_params", "Indica una terminal sin identificadores contradictorios")
        record = next((value for value in workspace["windows"] if value["id"] == ids[0]), None)
        if record is None:
            raise RPCError("not_found", "No se encontró la terminal")
        return workspace, record, self.window.surfaces.get(record["id"])

    def workspace_list(self, params):
        values = self.window.store.workspaces
        if params.get("workspace_id") is not None:
            values = [self.target(params, terminal=False)[0]]
        terminals_filter = [params[key] for key in ("surface_id", "terminal_id", "tab_id") if params.get(key) is not None]
        if terminals_filter and not all(isinstance(value, str) and value == terminals_filter[0] for value in terminals_filter):
            raise RPCError("invalid_params", "Identificadores de terminal contradictorios")
        boxes = []
        for workspace in values:
            terminals = []
            for record in workspace["windows"]:
                if terminals_filter and record["id"] != terminals_filter[0]:
                    continue
                surface = self.window.surfaces.get(record["id"])
                terminals.append({"id": record["id"], "title": record["name"],
                                  "current_directory": record.get("cwd") or workspace.get("cwd"),
                                  "is_ready": bool(surface and surface.pid and not surface.disposed),
                                  "is_focused": surface is self.window.focused_surface and surface is not None,
                                  "runtime_state": record.get("runtimeState"), "agent": record.get("agent"),
                                  "tmux_binding": {"name": record["tmux"], "socketName": record.get("tmuxSocket") or
                                                   ("uniconnect" if workspace["kind"] == "ssh" else "uniconnect-local")}
                                  if record.get("tmux") else None})
            targets = [("terminal", "Terminal")]
            if workspace["kind"] == "local":
                targets += [("claude", "Claude Code"), ("codex", "Codex"), ("agy", "Agy"), ("grok", "Grok")]
            boxes.append({"id": workspace["id"], "title": workspace["name"], "kind": workspace["kind"],
                          "current_directory": workspace.get("cwd"), "is_pinned": workspace.get("pinned", False),
                          "is_selected": workspace["id"] == self.window.store.data.get("selectedWorkspaceId"),
                          "available_agent_targets": [{"id": key, "title": title} for key, title in targets],
                          "terminals": terminals})
        if terminals_filter and not any(box["terminals"] for box in boxes):
            raise RPCError("not_found", "No se encontró la terminal")
        return {"workspaces": boxes}

    def invalidate_terminal(self, panel_id):
        with self.revision_lock:
            self.capture_versions[panel_id] = self.capture_versions.get(panel_id, 0) + 1

    def replay(self, params, *, authorized=lambda: True):
        if not capture_dependencies_ready():
            raise RPCError("snapshot_unavailable", "Falta la dependencia Unicode del acceso móvil; ejecuta linux/install.sh")
        def identity(workspace, record, surface):
            profile = getattr(surface, "mobile_color_profile", {})
            return (id(workspace), id(record), workspace.get("credentialId"), workspace["kind"],
                    record.get("tmux"), record.get("tmuxSocket"), id(surface), getattr(surface, "generation", None),
                    tuple(profile.get("palette", ())), profile.get("foreground"), profile.get("background"))
        def prepare():
            if not authorized():
                raise RPCError("approval_required", "El permiso de este dispositivo ha sido revocado")
            if self.window.locked:
                raise RPCError("locked", "UniConnect está bloqueado")
            workspace, record, surface = self.target(params)
            if not record.get("tmux"):
                raise RPCError("snapshot_unavailable", "Esta consola antigua no ofrece una pantalla tmux recuperable")
            if surface is None:
                attach = getattr(self.window, "ensure_mobile_surface", None)
                if attach is not None:
                    surface = attach(workspace, record)
            if surface is None or surface.disposed or not getattr(surface, "mobile_color_profile", None):
                raise RPCError("surface_unavailable", "Esta terminal no está abierta en el escritorio")
            command = SSHCommand.parse(self.window.connection(workspace)) if workspace["kind"] == "ssh" else None
            return (workspace["id"], dict(record), command, identity(workspace, record, surface),
                    dict(surface.mobile_color_profile))
        prepared = self.on_main(prepare)
        panel_id = prepared[1]["id"]
        lock = self.capture_locks[hash(panel_id) % len(self.capture_locks)]
        if not lock.acquire(timeout=5):
            raise RPCError("busy", "El escritorio está ocupado; vuelve a intentarlo")
        try:
            # Re-resolve after waiting: never use a replaced surface's credentials.
            workspace_id, record, command, original_identity, profile = self.on_main(prepare)
            interval = 0.75 if command else 0.25
            with self.revision_lock:
                version = self.capture_versions.get(panel_id, 0)
                cached = self.capture_cache.get(panel_id)
                started = self.capture_started.get(panel_id, -float("inf"))
            def still_current():
                if not authorized() or self.window.locked:
                    raise RPCError("locked", "El acceso a la terminal está bloqueado")
                target = self.target(params)
                if identity(*target) != original_identity or target[2].disposed:
                    raise RPCError("snapshot_unavailable", "La terminal ha cambiado durante la captura; vuelve a intentarlo")
            if (cached and cached[0] == original_identity and cached[1] == version
                    and self.clock() - started < interval):
                self.on_main(still_current)
                return cached[2]
            # Coalesce bursts on a worker, never GTK. A dirty frame waits then
            # captures; returning a stale cached frame would lose the last event.
            delay = interval - (self.clock() - started)
            if delay > 0:
                self.wait(delay)
            self.on_main(still_current)
            with self.revision_lock:
                version = self.capture_versions.get(panel_id, 0)
                self.capture_started[panel_id] = self.clock()
            socket_name = record.get("tmuxSocket") or ("uniconnect" if command else "uniconnect-local")
            target = "=" + record["tmux"] + ":"
            marker = "UC_CAPTURE_" + uuid.uuid4().hex
            # One read-only tmux command group; the nonce excludes login banners.
            # No attach, ensure_session, second PTY reader or terminal input.
            arguments = ["tmux", "-L", socket_name, "display-message", "-p", "-t", target, marker,
                         ";", "capture-pane", "-p", "-e", "-N", "-S", str(-MAX_SCROLLBACK_ROWS), "-t", target,
                         ";", "display-message", "-p", "-t", target,
                         "UC_META\t#{pane_width}\t#{pane_height}\t#{cursor_x}\t#{cursor_y}\t#{cursor_flag}\t#{alternate_on}"]
            try:
                output = self.transport_factory(command, socket_name=socket_name).run(shlex.join(arguments), timeout=5).stdout
                prefix, separator, capture = output.partition(marker + "\n")
                if not separator or (prefix and not prefix.endswith("\n")):
                    raise ValueError("capture marker")
                screen, metadata = capture.rstrip("\n").rsplit("\n", 1)
                meta, columns, rows, x, y, visible, alternate = metadata.split("\t")
                columns, rows, x, y = map(int, (columns, rows, x, y))
                if meta != "UC_META" or visible not in ("0", "1") or alternate not in ("0", "1"):
                    raise ValueError("capture metadata")
                # capture-pane prints one line per physical row, including blank
                # viewport rows. Keep one capture so styles continue correctly
                # across the history/viewport boundary, without another SSH read.
                history_rows = max(0, screen.count("\n") + 1 - rows)
                frame = render_grid_from_tmux_capture(
                    screen, surface_id=panel_id, columns=columns, rows=rows,
                    cursor_column=max(0, min(x, columns - 1)), cursor_row=max(0, min(y, rows - 1)),
                    cursor_visible=visible == "1", alternate_screen=alternate == "1", revision=0,
                    palette=profile["palette"], default_foreground=profile["foreground"],
                    default_background=profile["background"], scrollback_rows=history_rows)
            except Exception as error:
                raise RPCError("snapshot_unavailable", "No se pudo representar la pantalla de la sesión existente") from error
            digest = hashlib.sha256(json.dumps(frame, sort_keys=True, ensure_ascii=False).encode()).digest()
            self.on_main(still_current)
            with self.revision_lock:
                prior_digest, revision = self.revisions.get(panel_id, (None, 0))
                if digest != prior_digest:
                    revision += 1
                self.revisions[panel_id] = (digest, revision)
                frame["state_seq"] = frame["revision"] = revision
                payload = {"workspace_id": workspace_id, "surface_id": panel_id, "seq": revision,
                           "revision": revision, "columns": columns, "rows": rows, "render_grid": frame}
                self.capture_cache[panel_id] = (original_identity, version, payload)
                self.capture_cache.move_to_end(panel_id)
                while len(self.capture_cache) > 8:
                    self.capture_cache.popitem(last=False)
            return payload
        finally:
            lock.release()

    def viewport(self, surface, params, connection_id):
        client_id = params.get("client_id")
        if not isinstance(client_id, str) or not client_id or len(client_id) > 128:
            raise RPCError("invalid_params", "Identificador de cliente no válido")
        panel_id = surface.record["id"]
        key = (connection_id, client_id, panel_id)
        if params.get("clear") is True:
            self.viewports.pop(key, None)
        else:
            cols, rows = params.get("viewport_columns"), params.get("viewport_rows")
            if type(cols) is not int or type(rows) is not int or not 20 <= cols <= 500 or not 5 <= rows <= 300:
                raise RPCError("invalid_params", "Tamaño de terminal no válido")
            if key not in self.viewports and sum(item[0] == connection_id for item in self.viewports) >= 8:
                raise RPCError("invalid_params", "Demasiados tamaños de terminal activos")
            self.original_sizes.setdefault(panel_id, (surface.terminal.get_column_count(), surface.terminal.get_row_count()))
            self.viewports[key] = (cols, rows)
        self.apply_viewport(panel_id)
        return {"columns": surface.terminal.get_column_count(), "rows": surface.terminal.get_row_count()}

    def apply_viewport(self, panel_id):
        surface = self.window.surfaces.get(panel_id)
        values = [value for key, value in self.viewports.items() if key[2] == panel_id]
        original = self.original_sizes.get(panel_id)
        if surface and original:
            sizes = [original] + values
            surface.terminal.set_size(min(size[0] for size in sizes), min(size[1] for size in sizes))
        if not values:
            self.original_sizes.pop(panel_id, None)

    def disconnected(self, connection_id):
        def clear():
            panels = {key[2] for key in self.viewports if key[0] == connection_id}
            self.viewports = {key: value for key, value in self.viewports.items() if key[0] != connection_id}
            for panel_id in panels:
                self.apply_viewport(panel_id)
            return False
        self.schedule(clear)

    def notifications(self, params):
        limit = params.get("limit", 100)
        if type(limit) is not int or not 1 <= limit <= 200:
            raise RPCError("invalid_params", "Límite de notificaciones no válido")
        cursor = None
        if params.get("before") is not None:
            try:
                raw = params["before"]
                if not isinstance(raw, str) or len(raw) > 512:
                    raise ValueError()
                value = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
                cursor = (value["created_at_ms"], value["id"])
                if type(cursor[0]) is not int or not isinstance(cursor[1], str):
                    raise ValueError()
            except Exception as error:
                raise RPCError("invalid_params", "Cursor de notificaciones no válido") from error
        values = sorted(self.window.store.data.get("notificationHistory", []),
                        key=lambda item: (item["created_at_ms"], item["id"]), reverse=True)
        if cursor:
            values = [item for item in values if (item["created_at_ms"], item["id"]) < cursor]
        page = values[:limit]
        next_cursor = None
        if len(values) > limit:
            item = page[-1]
            raw = json.dumps({"created_at_ms": item["created_at_ms"], "id": item["id"]}, separators=(",", ":")).encode()
            next_cursor = base64.urlsafe_b64encode(raw).decode().rstrip("=")
        return {"notifications": page, "next_cursor": next_cursor}


def notification_record(workspace, record, stamp, identifier):
    return {"id": identifier, "workspace_id": workspace["id"], "surface_id": record["id"],
            "title": record["name"][:512], "subtitle": workspace["name"][:512], "body": "La sesión necesita tu atención",
            "created_at": datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).isoformat(),
            "created_at_ms": int(stamp * 1000), "is_read": False}
