"""Private local control socket compatible with the core cmux CLI operations."""

import json
import os
import socket
import stat
import struct
import time

from gi.repository import GLib

from .arrangement import WorkspaceArrangement
from .relaunch_agents import CAPABILITIES as RELAUNCH_CAPABILITIES
from .window_details import WindowDetails


class ControlServer:
    def __init__(self, window):
        self.window = window
        self.path = window.store.root / "control.sock"
        if self.path.exists():
            info = self.path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid():
                raise RuntimeError("Control socket path is not an owned socket")
            self.path.unlink()
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.bind(str(self.path))
        self.identity = self.path.stat().st_ino
        self.path.chmod(0o600)
        self.socket.listen(8)
        self.socket.setblocking(False)
        self.clients = {}
        self.watch = GLib.io_add_watch(self.socket.fileno(), GLib.IO_IN, self.accept)

    def accept(self, fd, condition):
        client, _ = self.socket.accept()
        credentials = client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
        _, uid, _ = struct.unpack("3i", credentials)
        if uid != os.geteuid():
            client.close()
            return True
        client.setblocking(False)
        watch = GLib.io_add_watch(client.fileno(), GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, self.receive, client)
        self.clients[client] = [bytearray(), watch]
        return True

    def receive(self, fd, condition, client):
        try:
            chunk = client.recv(65536)
            buffer = self.clients[client][0]
            buffer.extend(chunk)
            if len(buffer) > 131072:
                raise ValueError("Request is too large")
            if not chunk and b"\n" not in buffer:
                self.drop(client)
                return False
            if b"\n" not in buffer:
                return True
            request = json.loads(bytes(buffer).split(b"\n", 1)[0])
            if request.get("command") in ("relaunch.plan", "relaunch.apply", "relaunch.status"):
                # This socket is delivered on GTK: probing processes/SSH must
                # run on a worker, not block keyboard input or repainting.
                def work():
                    try:
                        return {"ok": True, "result": self.window.relaunch.dispatch(
                            request["command"], request.get("params", {}))}
                    except Exception as error:
                        return {"ok": False, "error": {"code": getattr(error, "code", "internal_error"),
                                                        "message": str(error)}}
                self.window.background(work, lambda result: self.respond(client, result))
                self.clients[client][1] = None  # This read watch is removed on return.
                return False
            if request.get("command") in ("save", "persist", "surface.details", "details"):
                # Guardar espera a la sonda (≤ 10 s) y Detalles la lee: la respuesta llega
                # cuando está hecho, sin bloquear GTK. Nunca «saved» antes de persistir.
                self.clients[client][1] = None  # This read watch is removed on return.
                self.dispatch_later(request, lambda result: self.respond(client, result))
                return False
            result = {"ok": True, "result": self.dispatch(request)}
        except Exception as error:
            result = {"ok": False, "error": str(error)}
        return self.respond(client, result)

    def respond(self, client, result):
        if client not in self.clients:
            return False
        try:
            # Bounded response and tiny deadline prevent a client from blocking GTK.
            client.settimeout(0.05)
            client.sendall(json.dumps(result, ensure_ascii=False).encode() + b"\n")
        except OSError:
            pass
        self.drop(client)
        return False

    def drop(self, client):
        self.clients.pop(client, None)
        client.close()

    def target(self, request):
        """(espacios ordenados, id del espacio, espacio, id de la ventana) que nombra la petición."""
        workspaces = WorkspaceArrangement.ordered(self.window.store.workspaces)
        workspace_id = request.get("workspace") or self.window.store.data.get("selectedWorkspaceId")
        if isinstance(workspace_id, str) and workspace_id.startswith("workspace:"):
            workspace_id = workspaces[int(workspace_id.split(":")[1]) - 1]["id"]
        workspace = next((w for w in workspaces if w["id"] == workspace_id), None)
        surface_id = request.get("surface") or (workspace.get("selectedWindowId") if workspace else None)
        return workspaces, workspace_id, workspace, surface_id

    def dispatch_later(self, request, reply):
        """«save» y «details»: se contestan cuando terminan de verdad (hilo GTK)."""
        try:
            if self.window.locked:
                raise ValueError("UniConnect is locked")
            if request["command"] in ("save", "persist"):
                def saved(error=None):
                    reply({"ok": True, "result": "saved"} if error is None else {"ok": False, "error": str(error)})
                self.window.action_save(done=saved)
                return
            _, _, workspace, surface_id = self.target(request)
            record = next((item for item in (workspace or {}).get("windows", []) if item["id"] == surface_id), None)
            if record is None:
                raise ValueError("Unknown surface")
            # Mismo JSON que mobile.terminal.details: resolución aquí, ssh -G y sonda fuera de GTK.
            workspace_copy, record_copy, connection, transport = self.window.details_inputs(workspace, record)
            catalog = self.window._details_catalog()

            def work():
                try:
                    return {"ok": True, "result": WindowDetails.gather(
                        workspace_copy, record_copy, connection=connection, transport=transport,
                        catalog=catalog, clock=time.time)}
                except Exception as error:
                    return {"ok": False, "error": str(error)}
            self.window.background(work, reply)
        except Exception as error:
            reply({"ok": False, "error": str(error)})

    def dispatch(self, request):
        command = request.get("command", "ping")
        if command == "ping":
            return {"app": "UniConnect", "platform": "linux", "locked": self.window.locked,
                    "capabilities": list(RELAUNCH_CAPABILITIES) if hasattr(self.window, "relaunch") else []}
        if self.window.locked:
            raise ValueError("UniConnect is locked")
        workspaces, workspace_id, workspace, surface_id = self.target(request)
        if command in ("list-workspaces", "workspace.list"):
            return [{"id": w["id"], "name": w["name"], "kind": w["kind"], "windows": len(w["windows"]),
                     "selected": w["id"] == self.window.store.data.get("selectedWorkspaceId")} for w in workspaces]
        if command in ("list-surfaces", "surface.list"):
            return [{"id": p["id"], "name": p["name"], "tmux": p.get("tmux"), "sessionId": p.get("sessionId"),
                     "status": self.window.surfaces[p["id"]].status if p["id"] in self.window.surfaces else "saved"}
                    for p in WorkspaceArrangement.ordered((workspace or {}).get("windows", []))]
        if command in ("current-workspace", "identify"):
            return {"workspace": workspace_id, "surface": surface_id}
        if command in ("select-workspace", "workspace.select"):
            if workspace is None:
                raise ValueError("Unknown workspace")
            self.window.select_workspace(workspace_id)
            return workspace_id
        surface = self.window.surfaces.get(surface_id)
        if surface is None:
            raise ValueError("Select the workspace before controlling its surface")
        if command in ("focus-surface", "surface.focus"):
            self.window.select_workspace(surface.workspace["id"])
            parent = surface.get_parent()
            parent.set_current_page(parent.page_num(surface))
            surface.terminal.grab_focus()
            return surface_id
        if command in ("send", "send-text"):
            surface.send(request.get("text", ""))
            return "sent"
        if command == "send-key":
            keys = {"Enter": "\r", "Tab": "\t", "Escape": "\x1b", "C-c": "\x03", "C-d": "\x04"}
            if request.get("text") not in keys:
                raise ValueError("Unsupported key")
            surface.send(keys[request["text"]])
            return "sent"
        if command == "read-screen":
            from gi.repository import Vte
            content = surface.terminal.get_text_format(Vte.Format.TEXT)
            return (content or "")[-65536:]
        if command == "reconnect":
            surface.launch()
            return "reconnecting"
        if command == "close-surface":
            self.window.close_surface(surface)
            return "closed"
        raise ValueError("Unsupported control command")

    def close(self):
        GLib.source_remove(self.watch)
        for client, (_, watch) in list(self.clients.items()):
            if watch is not None:
                GLib.source_remove(watch)
            self.drop(client)
        self.socket.close()
        if self.path.exists() and self.path.stat().st_ino == self.identity:
            self.path.unlink()
