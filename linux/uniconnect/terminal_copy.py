"""Explicit tmux selection export; no OSC clipboard trust or global-buffer fallback."""

import shlex
import uuid

from .transport import TmuxCommand, TransportError
from .terminal_selection import TerminalSelection


class TerminalCopy:
    def __init__(self, transport):
        self.transport = transport

    def resolve_pane(self, record, pane=None, missing=71):
        if pane is not None:
            return TerminalSelection(self.transport).guard(pane) + f'uc_pane={shlex.quote(pane["id"])}; '
        target = shlex.quote("=" + TmuxCommand.validate_name(record["tmux"]) + ":")
        binary = TmuxCommand._binary(self.transport.socket_name)
        return f'uc_pane=$({binary} display-message -p -t {target} "#{{pane_id}}") || exit {missing}; '

    def cancel_selection(self, record, pane=None):
        """An explicit desktop reconnect may leave copy mode, never send agent input."""
        binary = TmuxCommand._binary(self.transport.socket_name)
        self.transport.run(
            self.resolve_pane(record, pane, missing=0) +
            f'if [ "$({binary} display-message -p -t "$uc_pane" "#{{pane_mode}}")" = copy-mode ]; then '
            f'{binary} send-keys -t "$uc_pane" -X cancel; fi', timeout=15)

    def read_selection(self, record, pane=None):
        """Copy only this pane's current selection, then leave copy mode.

        Runs off the GTK thread, locally or over the existing SSH transport.
        A unique prefix prevents another pane's last buffer being copied.
        """
        binary = TmuxCommand._binary(self.transport.socket_name)
        prefix = "uc-clipboard-" + uuid.uuid4().hex + "-"
        script = (
            self.resolve_pane(record, pane) +
            f'test "$({binary} display-message -p -t "$uc_pane" "#{{selection_present}}")" = 1 || exit 72; '
            f'{binary} send-keys -t "$uc_pane" -X copy-selection-no-clear {prefix} || exit 71; '
            f'for uc_buffer in $({binary} list-buffers -F "#{{buffer_name}}"); do '
            f'case "$uc_buffer" in {prefix}*) '
            f'{binary} save-buffer -b "$uc_buffer" -; uc_result=$?; '
            f'{binary} delete-buffer -b "$uc_buffer"; '
            f'if [ "$uc_result" = 0 ]; then {binary} send-keys -t "$uc_pane" -X cancel; fi; '
            'exit "$uc_result";; esac; done; exit 72'
        )
        result = self.transport.run(script, timeout=15, check=False)
        if result.returncode == 72:
            raise TransportError("Selecciona texto antes de copiar.")
        if result.returncode:
            # Never display remote stderr: it may contain selected private text.
            raise TransportError("No se pudo copiar la selección del terminal.")
        return result.stdout
