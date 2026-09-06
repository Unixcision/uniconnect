"""GTK-owned gesture state with one bounded worker and coalesced edge scrolling."""

import threading
from collections import deque

from gi.repository import GLib

from .terminal_selection import TerminalSelection


class SelectionDrag:
    def __init__(self, surface):
        self.surface = surface
        self.epoch = 0
        self.busy = False
        self.active = self.pressed = False
        self.pane = None
        self.pending_begin = self.pending_move = None
        self.actions = deque()
        self.timer = None
        self.point = (0, 0)

    def reset(self):
        self.epoch += 1
        self.active = self.pressed = False
        self.pane = None
        self.pending_begin = self.pending_move = None
        self.actions.clear()
        self._stop_timer()

    def begin(self, transport, record, column, row):
        self.reset()
        self.active = self.pressed = True
        self.backend = TerminalSelection(transport)
        self.point = (column, row)
        self.pending_begin = (dict(record), column, row)
        self._pump()

    def motion(self, column, row):
        if not self.pressed:
            return False
        self.point = (column, row)
        self.pending_move = (column, row, 0)
        self._update_timer()
        self._pump()
        return True

    def finish(self):
        if self.pressed:
            self.pending_move = (*self.point, 0)
        self.pressed = False
        self._stop_timer()
        self._pump()

    def run_action(self, work, deliver, *, discard_motion=False):
        self.finish()
        if discard_motion:
            self.pending_begin = self.pending_move = None
        self.actions.append((work, deliver))
        self._pump()

    def _stop_timer(self):
        if self.timer is not None:
            GLib.source_remove(self.timer)
            self.timer = None

    def _edge(self):
        if not self.pane:
            return 0
        row = self.point[1]
        top, bottom = self.pane["top"], self.pane["top"] + self.pane["height"] - 1
        if row < top:
            return -min(12, max(1, top - row))
        if row > bottom:
            return min(12, max(1, row - bottom))
        return 0

    def _update_timer(self):
        if self.pressed and self._edge():
            if self.timer is None:
                # This is the user-requested continuous edge-scroll cadence,
                # not a delay used to wait for a worker or guess readiness.
                self.timer = GLib.timeout_add(80, self._tick)
        else:
            self._stop_timer()

    def _tick(self):
        if not self.pressed or not self.active or not self._edge():
            self.timer = None
            return False
        self.pending_move = (*self.point, self._edge())
        self._pump()
        return True

    def _pump(self):
        if self.busy or self.surface.disposed:
            return
        epoch = self.epoch
        backend = getattr(self, "backend", None)
        if self.pending_begin:
            arguments, self.pending_begin = self.pending_begin, None
            kind, deliver = "begin", None
            work = lambda: backend.begin(*arguments)
        elif self.pending_move and self.pane:
            arguments, self.pending_move = self.pending_move, None
            pane = self.pane
            kind, deliver = "move", None
            work = lambda: backend.move(pane, *arguments)
        elif self.actions:
            work, deliver = self.actions.popleft()
            kind = "action"
        else:
            return
        self.busy = True

        def execute():
            value = error = None
            try:
                value = work()
            except Exception as caught:
                error = caught
            GLib.idle_add(self._complete, epoch, kind, value, error, deliver)

        threading.Thread(target=execute, name="uniconnect-selection", daemon=True).start()

    def _complete(self, epoch, kind, value, error, deliver):
        self.busy = False
        if epoch == self.epoch and not self.surface.disposed:
            if kind == "action":
                deliver(value, error)
            elif error:
                self.active = self.pressed = False
                self.pending_begin = self.pending_move = None
                self._stop_timer()
                self.surface.owner.error(self.surface.owner._("No se pudo seleccionar el historial del terminal."))
            elif kind == "begin":
                self.pane = value
                self._update_timer()
        self._pump()
        return False
