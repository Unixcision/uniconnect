"""Ciclo de actividad del escritorio: sonda tmux fuera de GTK, decide en el hilo del modelo.

Cada ~2 s recoge los hechos de cada ventana viva (comando en primer plano, título,
salida reciente), evalúa con ``ActivityResolver`` y, si algún estado cambia,
refresca la barra lateral y publica ``workspace.updated`` (coalescido a ≥ 1 s en
``MobileDesktop``). Las cajas SSH se sondean por la misma vía que ya usa el
escritorio para hablar con el remoto, con menos frecuencia.
"""

import math
import os
import time
from pathlib import Path

from gi.repository import GLib

from .activity import ActivityResolver, aggregate_state, parse_list_panes, probe_script
from .transport import Transport


class ActivityMonitor:
    INTERVAL_SECONDS = 2.0
    SSH_INTERVAL_SECONDS = 10.0

    def __init__(self, window, *, resolver=None, transport=Transport, clock=time.time,
                 interval=INTERVAL_SECONDS, ssh_interval=SSH_INTERVAL_SECONDS):
        self.window = window
        self.resolver = resolver or ActivityResolver(clock=clock)
        self.transport, self.clock = transport, clock
        self.interval, self.ssh_interval = interval, ssh_interval
        self.pending = set()
        self.ssh_probed = {}
        self.source = None

    # ----- ciclo -----

    def start(self):
        if self.source is None:
            self.source = GLib.timeout_add(max(1, int(self.interval * 1000)), self.cycle)

    def stop(self):
        if self.source is not None:
            GLib.source_remove(self.source)
            self.source = None

    # ----- hechos desde las señales de VTE y del móvil (hilo GTK) -----

    def note_output(self, window_id):
        self.resolver.note_output(window_id)

    def note_input(self, window_id):
        self.resolver.note_input(window_id)

    def note_resize(self, window_id):
        self.resolver.note_resize(window_id)

    def forget(self, window_id):
        self.resolver.forget(window_id)

    # ----- lecturas -----

    def activity(self, window_id):
        return self.resolver.current(window_id)

    def workspace_state(self, workspace):
        return aggregate_state(self.activity(record["id"]).state for record in workspace.get("windows", []))

    @staticmethod
    def foreground_command(surface):
        """Comando en primer plano del PTY de una ventana local sin tmux (solo Linux)."""
        try:
            pty = surface.terminal.get_pty()
            if pty is None:
                return None
            group = os.tcgetpgrp(pty.get_fd())
            return Path(f"/proc/{group}/comm").read_text().strip() or None
        except Exception:
            return None

    @staticmethod
    def screen_lines(surface):
        """Últimas líneas visibles del VTE; el texto se inspecciona y se descarta, nunca se registra."""
        try:
            result = surface.terminal.get_text(None, None)
            text = result[0] if isinstance(result, tuple) else result
        except Exception:
            try:
                text = surface.terminal.get_text()
                text = text[0] if isinstance(text, tuple) else text
            except Exception:
                return None
        if not isinstance(text, str):
            return None
        lines = [line for line in text.splitlines() if line.strip()]
        return lines[-12:]

    def cycle(self):
        window = self.window
        if window._closed:
            self.source = None
            return False
        if window.locked:
            return True
        groups = {}
        for surface in tuple(window.surfaces.values()):
            record, workspace = surface.record, surface.workspace
            if surface.disposed or not surface.pid:
                self.resolver.note_alive(record["id"], False, launched=record.get("agent"))
                continue
            self.resolver.note_alive(record["id"], True, launched=record.get("agent"))
            if record.get("tmux"):
                socket = record.get("tmuxSocket") or ("uniconnect" if workspace["kind"] == "ssh" else "uniconnect-local")
                key = (workspace["id"] if workspace["kind"] == "ssh" else "local", socket)
                groups.setdefault(key, []).append((surface, record, workspace))
            else:
                title = None
                try:
                    title = surface.terminal.get_window_title() or ""
                except Exception:
                    pass
                self.resolver.note_probe(record["id"], self.foreground_command(surface), title)
        for key, targets in groups.items():
            if key in self.pending:
                continue
            workspace = targets[0][2]
            command = None
            if workspace["kind"] == "ssh":
                last = self.ssh_probed.get(workspace["id"], -math.inf)
                if time.monotonic() - last < self.ssh_interval:
                    continue
                vault = getattr(window, "vault", None)
                if vault is not None and vault.locked:
                    continue
                try:
                    command = window.connection(workspace)
                except Exception:
                    continue
                self.ssh_probed[workspace["id"]] = time.monotonic()
            try:
                transport = self.transport(command, socket_name=key[1])
            except Exception:
                continue
            self.pending.add(key)
            def work(transport=transport):
                try:
                    output = transport.run(probe_script(transport.socket_name), timeout=8, check=False).stdout
                    return parse_list_panes(output)
                except Exception:
                    return None
            def done(result, key=key, targets=targets):
                self.pending.discard(key)
                if result is None or window._closed:
                    return
                for surface, record, workspace in targets:
                    if surface.disposed or window.surfaces.get(record["id"]) is not surface:
                        continue
                    entry = result.get(record.get("tmux"))
                    if entry is not None:
                        self.resolver.note_probe(record["id"], *entry)
                self.evaluate()
            window.background(work, done)
        self.evaluate()
        return True

    def evaluate(self):
        window = self.window
        changed = False
        alive = set()
        for surface in tuple(window.surfaces.values()):
            if surface.disposed:
                continue
            window_id = surface.record["id"]
            alive.add(window_id)
            previous = self.resolver.current(window_id)
            current = self.resolver.evaluate(window_id, screen=lambda surface=surface: self.screen_lines(surface))
            if (current.state, current.agent) != (previous.state, previous.agent):
                changed = True
        for window_id in [key for key in self.resolver.facts if key not in alive]:
            if self.resolver.current(window_id).state != "unknown":
                changed = True
            self.resolver.forget(window_id)
        if changed:
            window.refresh_sidebar()
        return changed
