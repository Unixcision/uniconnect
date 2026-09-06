"""Coordinate selection in the pane's real history, never in an agent's input."""

import re
import shlex

from .transport import TmuxCommand, TransportError


class TerminalSelection:
    identity_format = "#{session_name}|#{pane_pid}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}"

    def __init__(self, transport):
        self.transport = transport
        self.binary = TmuxCommand._binary(transport.socket_name)

    def begin(self, record, column, row):
        name = TmuxCommand.validate_name(record["tmux"])
        target = shlex.quote("=" + name + ":")
        fmt = "#{pane_id}|" + self.identity_format + "|#{status-position}|#{status}"
        result = self.transport.run(f"{self.binary} display-message -p -t {target} {shlex.quote(fmt)}", timeout=15)
        fields = result.stdout.rstrip("\n").split("|")
        if len(fields) != 9 or not re.fullmatch(r"%[0-9]+", fields[0]) or fields[1] != name:
            raise TransportError("No se pudo seleccionar el historial del terminal.")
        pid, left, top, width, height = map(int, fields[2:7])
        if pid < 1 or not (1 <= width <= 4096 and 1 <= height <= 4096):
            raise TransportError("No se pudo seleccionar el historial del terminal.")
        status_rows = {"off": 0, "on": 1}.get(fields[8])
        if status_rows is None:
            status_rows = int(fields[8])
        offset = status_rows if fields[7] == "top" else 0
        pane = {"id": fields[0], "identity": "|".join(fields[1:7]),
                "left": left, "top": top + offset, "width": width, "height": height}
        if not (left <= column < left + width and pane["top"] <= row < pane["top"] + height):
            raise TransportError("No se pudo seleccionar el historial del terminal.")
        script = self._guard(pane)
        script += (f'case "$({self.binary} display-message -p -t {pane["id"]} "#{{pane_mode}}")" in '
                   '""|copy-mode) ;; *) exit 73;; esac; ')
        script += f"{self.binary} copy-mode -t {pane['id']} || exit 73; "
        script += self._keys(pane, "clear-selection") + "; "
        script += self._keys(pane, "rectangle-off") + "; "
        script += self._position(pane, column, row)
        script += self._keys(pane, "begin-selection")
        self._run(script)
        return pane

    def move(self, pane, column, row, scroll=0):
        script = self._guard(pane)
        script += (f'test "$({self.binary} display-message -p -t {pane["id"]} '
                   '"#{pane_mode}|#{selection_present}")" = "copy-mode|1" || exit 73; ')
        if scroll:
            command = "scroll-up" if scroll < 0 else "scroll-down"
            script += self._keys(pane, command, min(12, abs(scroll))) + "; "
        self._run(script + self._position(pane, column, row))

    def _guard(self, pane):
        return (f'test "$({self.binary} display-message -p -t {pane["id"]} '
                f'{shlex.quote(self.identity_format)})" = {shlex.quote(pane["identity"])} || exit 73; ')

    def _keys(self, pane, command, count=None):
        count_flag = f" -N {int(count)}" if count else ""
        return f"{self.binary} send-keys -t {pane['id']} -X{count_flag} {command}"

    def _position(self, pane, column, row):
        x = max(0, min(pane["width"] - 1, int(column) - pane["left"]))
        y = max(0, min(pane["height"] - 1, int(row) - pane["top"]))
        script = self._keys(pane, "top-line") + " || exit 73; "
        if y:
            script += self._keys(pane, "cursor-down", y) + " || exit 73; "
        if x:
            # Cursor-right wraps at the text's end and skips wide-cell padding.
            # Compare actual cell coordinates inside tmux instead of assuming
            # N key steps == N columns or letting a blank click wrap a line.
            script += self._keys(pane, "end-of-line") + " || exit 73; "
            script += (f'uc_selection_end=$({self.binary} display-message -p -t {pane["id"]} '
                       '"#{copy_cursor_x}") || exit 73; '
                       'case "$uc_selection_end" in ""|*[!0-9]*) exit 73;; esac; ')
        script += self._keys(pane, "start-of-line") + " || exit 73; "
        condition = (f'#{{&&:#{{<:#{{copy_cursor_x}},{x}}},'
                     '#{<:#{copy_cursor_x},$uc_selection_end}}')
        step = (f'if-shell -F -t {pane["id"]} "{condition}" '
                f'{shlex.quote(self._keys(pane, "cursor-right").removeprefix(self.binary + " "))}')
        # A fixed-size conditional batch bounds the entire SSH argument too,
        # not only the nested tmux invocations. Comparisons stop at the cell
        # requested, including clicks inside wide characters or after EOL.
        if x:
            batch = min(32, x)
            script += f'uc_selection_steps=0; while [ "$uc_selection_steps" -lt {x} ]; do '
            script += self.binary + " " + " \\; ".join([step] * batch) + " || exit 73; "
            script += f"uc_selection_steps=$((uc_selection_steps+{batch})); done; "
        return script

    def _run(self, script):
        result = self.transport.run(script, timeout=15, check=False)
        if result.returncode:
            raise TransportError("No se pudo seleccionar el historial del terminal.")
