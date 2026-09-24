"""Árbol IA vivo en Linux: sondea todas las cajas y persiste qué IA corre en cada ventana.

Una sola lectura por grupo (caja SSH o equipo local, socket tmux) con la sonda
compartida agent_probe.py, en segundo plano. El resultado se aplica en el hilo GTK:
solo cambia lo guardado cuando la sonda confirma algo nuevo (contracts/agent-tree-v1).
"""

import copy
import json
import time
import uuid
from pathlib import Path

from .transport import SSHCommand, Transport, TransportError

PROBE_SOURCE = Path(__file__).with_name("agent_probe.py")
AGENTS = ("claude", "codex", "agy", "grok")
SOURCES = ("ficha", "rollout", "argv", "hook", "manifiesto", "registro")
HISTORY_LIMIT = 32


class AgentTree:
    LOCAL_INTERVAL = 8
    SSH_INTERVAL = 60
    PROBE_TIMEOUT = 8
    SAVE_DEADLINE = 10

    def __init__(self, owner, *, transport=Transport, clock=time.monotonic, wall=time.time, schedule=None):
        self.owner, self.transport = owner, transport
        self.clock, self.wall = clock, wall
        self._schedule = schedule
        self.pending = set()
        self.last = {}
        self.waiters = {}
        # Última lectura viva por ventana, solo en memoria: la usan Detalles y control.
        self.live = {}

    # ----- grupos -----

    @staticmethod
    def socket_of(workspace, record):
        return record.get("tmuxSocket") or ("uniconnect" if workspace["kind"] == "ssh" else "uniconnect-local")

    @classmethod
    def group_key(cls, workspace, record):
        # Las cajas locales comparten un servidor; las remotas mantienen su credencial.
        return (workspace["id"] if workspace["kind"] == "ssh" else "local", cls.socket_of(workspace, record))

    def groups(self):
        """Todas las cajas guardadas, no solo las construidas en pantalla."""
        groups = {}
        for workspace in self.owner.store.workspaces:
            for record in workspace.get("windows", []):
                if record.get("tmux"):
                    groups.setdefault(self.group_key(workspace, record), []).append((workspace, record))
        return groups

    def busy(self):
        owner = self.owner
        operation = getattr(owner, "_runtime_operation", None)
        return bool(getattr(owner, "_closed", False) or owner.locked
                    or getattr(owner.store, "_active_transaction", None) is not None
                    or (operation is not None and operation.active))

    def schedule(self, seconds, callback):
        if self._schedule is not None:
            return self._schedule(seconds, callback)
        from gi.repository import GLib
        return GLib.timeout_add(max(1, int(seconds * 1000)), callback)

    # ----- sondeo -----

    @staticmethod
    def probe(transport, socket_name, sessions=(), *, timeout=PROBE_TIMEOUT):
        """Ejecuta la sonda en el destino del transporte y devuelve su JSON v1."""
        arguments = ["--socket", socket_name]
        for name in sessions:
            arguments += ["--session", name]
        result = transport.run_python(PROBE_SOURCE.read_bytes(), arguments, timeout=timeout)
        if result.returncode != 0:
            raise TransportError("probe_failed", (result.stderr or "").strip()[-500:] or str(result.returncode))
        # Un perfil de login puede imprimir algo antes: la sonda escribe una sola línea JSON al final.
        line = next((item for item in reversed((result.stdout or "").splitlines()) if item.startswith("{")), "")
        data = json.loads(line)
        if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("sessions"), list):
            raise TransportError("probe_invalid")
        return data

    @staticmethod
    def open_transport(owner, factory, key, workspace):
        """Transporte de un grupo, o None si no se puede abrir sin preguntar (bóveda cerrada)."""
        command = None
        if key[0] != "local":
            vault = getattr(owner, "vault", None)
            if vault is None or vault.locked:
                return None
            try:
                command = SSHCommand.parse(owner.connection(workspace))
            except Exception:
                return None
        return factory(command, socket_name=key[1])

    def transport_for(self, key, workspace):
        return self.open_transport(self.owner, self.transport, key, workspace)

    def poll(self, *, force=False):
        """Lanza las lecturas que tocan (local cada 8 s, SSH cada 60 s); nunca dos por grupo."""
        if self.busy():
            return []
        started, now = [], self.clock()
        for key, targets in self.groups().items():
            if key in self.pending:
                continue
            interval = self.LOCAL_INTERVAL if key[0] == "local" else self.SSH_INTERVAL
            # El tick de 8 s tiene holgura: medio segundo de retraso no salta una lectura.
            if not force and key in self.last and now - self.last[key] < interval - 0.5:
                continue
            if self.start(key, targets):
                started.append(key)
        return started

    def start(self, key, targets):
        transport = self.transport_for(key, targets[0][0])
        if transport is None:
            return False
        sessions = sorted({record["tmux"] for _, record in targets})
        self.pending.add(key)
        self.last[key] = self.clock()

        def work():
            try:
                return self.probe(transport, key[1], sessions)
            except Exception as error:  # Nunca un diálogo de error por una lectura de fondo.
                return {"version": 1, "error": getattr(error, "code", type(error).__name__), "sessions": []}

        def done(result):
            self.pending.discard(key)
            try:
                self.apply(targets, result)
            except Exception:
                pass
            finally:
                for waiter in self.waiters.pop(key, []):
                    try:
                        waiter(key)
                    except Exception:
                        pass

        self.owner.background(work, done)
        return True

    def refresh_all(self, callback, *, timeout=None):
        """Refresco forzado de todas las cajas; ``callback`` se llama una vez, falle o venza la sonda."""
        fired = []

        def finish(*_):
            if not fired:
                fired.append(True)
                callback()
            return False

        if self.busy():
            return finish()
        started = set(self.poll(force=True))
        # Solo se espera a lo que sigue en vuelo (lo recién lanzado o una lectura anterior).
        keys = (started | set(self.groups())) & self.pending
        if not keys:
            return finish()
        remaining = set(keys)

        def one(key):
            remaining.discard(key)
            if not remaining:
                finish()

        for key in keys:
            self.waiters.setdefault(key, []).append(one)
        self.schedule(timeout or self.SAVE_DEADLINE, finish)
        return False

    # ----- aplicación (hilo GTK) -----

    def current(self, workspace, record):
        return (any(item is workspace for item in self.owner.store.workspaces)
                and any(item is record for item in workspace.get("windows", [])))

    def apply(self, targets, result):
        error = result.get("error") if isinstance(result, dict) else "probe_invalid"
        sessions = {} if error else {item.get("name"): item for item in result.get("sessions", [])
                                     if isinstance(item, dict)}
        checked = result.get("checked_at") if isinstance(result, dict) else None
        changed = []
        for workspace, record in targets:
            if not self.current(workspace, record):
                continue
            entry = sessions.get(record["tmux"])
            self.live[record["id"]] = {"ok": not error, "error": error, "checked_at": checked, "session": entry}
            if error or entry is None or self.busy():
                continue
            before = copy.deepcopy(record)
            if self.transition(record, entry, self.claimed(record)):
                changed.append((record, before))
        if not changed:
            return []
        try:
            self.owner.store.save()
        except Exception:
            for record, before in changed:
                record.clear()
                record.update(before)
            return []
        for record, _ in changed:
            surface = getattr(self.owner, "surfaces", {}).get(record["id"])
            if surface is not None and not surface.disposed:
                surface.update_status(surface.status)
        return [record for record, _ in changed]

    def claimed(self, record):
        """Conversaciones ya anotadas en otras ventanas: una conversación tiene una sola dueña.

        Si dos ventanas corren hoy la misma conversación, la segunda no la hereda: si no,
        el registro de dueños impediría volver a enganchar una de las dos al abrir.
        """
        return {(item.get("agent"), str(item.get("sessionId")).lower())
                for workspace in self.owner.store.workspaces for item in workspace.get("windows", [])
                if item is not record and item.get("sessionId")}

    def transition(self, record, entry, claimed=frozenset()):
        """Aplica una lectura viva a una ventana guardada; True si cambió algo."""
        reason, agent = entry.get("reason"), entry.get("agent")
        if reason == "sin_ia":
            # Shell sin IA: la última conversación queda guardada, pero no se reanuda sola.
            if record.get("runtimeState") == "shell" and not record.get("interrupted"):
                return False
            record["runtimeState"] = "shell"
            if record.get("interrupted"):
                record["interrupted"] = False
            return True
        if reason is not None or not isinstance(agent, dict):
            return False  # Ambigua, sin id, panel muerto: no se toca nada guardado.
        provider, session = agent.get("provider"), agent.get("session_id")
        if provider not in AGENTS or not isinstance(session, str) or not session:
            return False
        if (provider, session.lower()) in claimed and record.get("sessionId") != session:
            return False  # La misma conversación ya es de otra ventana: como si fuera ambigua.
        cwd = agent.get("cwd") if isinstance(agent.get("cwd"), str) and agent["cwd"].startswith("/") else None
        source = agent.get("source") if agent.get("source") in SOURCES else "registro"
        updates = {"agent": provider, "sessionId": session, "runtimeState": "agent",
                   "asRoot": bool(agent.get("as_root")), "agentSource": source}
        if cwd:
            updates["resumeCwd"] = cwd
        history = copy.deepcopy(record.get("history", []))
        now = self.wall()
        grown = False
        previous = (record.get("agent"), record.get("sessionId"), record.get("resumeCwd") or record.get("cwd"))
        for kind, identifier, folder in (previous, (provider, session, cwd)):
            if kind in AGENTS and identifier and not any(
                    item.get("agent") == kind and item.get("sessionId") == identifier for item in history):
                history.append({"id": str(uuid.uuid4()), "agent": kind, "sessionId": identifier, "cwd": folder,
                                "firstSeenAt": now, "lastSeenAt": now})
                grown = True
        changed = grown or any(record.get(key) != value for key, value in updates.items()) or bool(record.get("interrupted"))
        if not changed:
            return False
        if record.get("agent") != provider:
            record.pop("model", None)  # El modelo de otra IA no vale para esta.
        for item in history:
            if item.get("agent") == provider and item.get("sessionId") == session:
                item["lastSeenAt"] = now
                if cwd:
                    item["cwd"] = cwd
        while len(history) > HISTORY_LIMIT:
            history.pop(0)
        record.update(updates, agentObservedAt=now, interrupted=False, history=history)
        return True

    @staticmethod
    def client_exited(workspace, record):
        """Cierre del cliente tmux local: si la IA estaba activa queda interrumpida y se reanudará."""
        if workspace.get("kind") != "local":
            return
        if record.get("runtimeState") == "agent":
            record["interrupted"] = True
        record["runtimeState"] = "stopped"
