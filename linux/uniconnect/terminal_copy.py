"""Explicit tmux selection export; no OSC clipboard trust or global-buffer fallback."""

import shlex
import uuid

from .transport import TmuxCommand, TransportError


class TerminalCopy:
    def __init__(self, transport):
        self.transport = transport

    def cancel_selection(self, record):
        """An explicit desktop reconnect may leave copy mode, never send agent input."""
        target = shlex.quote("=" + TmuxCommand.validate_name(record["tmux"]) + ":")
        binary = TmuxCommand._binary(self.transport.socket_name)
        self.transport.run(
            f'uc_pane=$({binary} display-message -p -t {target} "#{{pane_id}}") || exit 0; '
            f'if [ "$({binary} display-message -p -t "$uc_pane" "#{{pane_mode}}")" = copy-mode ]; then '
            f'{binary} send-keys -t "$uc_pane" -X cancel; fi', timeout=15)

    def read_selection(self, record):
        """Copy only this pane's current selection, then leave copy mode.

        Runs off the GTK thread, locally or over the existing SSH transport.
        A unique prefix prevents another pane's last buffer being copied.
        """
        name = TmuxCommand.validate_name(record["tmux"])
        target = shlex.quote("=" + name + ":")
        binary = TmuxCommand._binary(self.transport.socket_name)
        prefix = "uc-clipboard-" + uuid.uuid4().hex + "-"
        script = (
            f'uc_pane=$({binary} display-message -p -t {target} "#{{pane_id}}") || exit 71; '
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
