"""One bounded, read-only snapshot of a pinned tmux pane, local or over SSH."""

import json
import shlex

from .transport import TmuxCommand, TransportError


# Sent as an argv value, never written on the remote host. No copy-mode,
# terminal input, global buffers, configuration changes or terminal escapes.
_CAPTURE = r'''
import json, re, subprocess, sys
binary, name = json.loads(sys.argv[1]), sys.argv[2]
def query(target):
    return subprocess.check_output(binary + ['display-message', '-p', '-t', target,
        '#{pane_id}|#{session_name}|#{pane_pid}'], timeout=8).decode().strip()
try:
    stamp = query('=' + name + ':')
    pane, session, pid = stamp.split('|')
    if not re.fullmatch(r'%[0-9]+', pane) or session != name or not pid.isdecimal():
        sys.exit(73)
    child = subprocess.Popen(binary + ['capture-pane', '-p', '-J', '-S', '-50000', '-E', '-', '-t', pane],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        output = child.stdout.read(8 * 1024 * 1024 + 1)
        if len(output) > 8 * 1024 * 1024:
            sys.exit(74)
        if child.wait(timeout=8) or query(pane) != stamp:
            sys.exit(73)
    finally:
        if child.poll() is None:
            child.terminate()  # Only this read-only capture client, never a pane.
            child.wait(timeout=3)
    print(json.dumps({'pane': pane, 'text': output.decode('utf-8', errors='replace')}))
except Exception:
    sys.exit(73)
'''


class TerminalHistory:
    def __init__(self, transport):
        self.transport = transport

    def capture(self, record):
        name = TmuxCommand.validate_name(record['tmux'])
        binary = shlex.split(TmuxCommand._binary(self.transport.socket_name))
        command = shlex.join(['python3', '-c', _CAPTURE, json.dumps(binary), name])
        result = self.transport.run(command, timeout=25, check=False)
        if result.returncode == 74:
            raise TransportError('El historial supera 8 MiB. Reduce el historial antes de abrirlo.')
        if result.returncode:
            raise TransportError('No se pudo leer el historial. Puedes seguir usando el terminal.')
        try:
            payload = json.loads(result.stdout)
            if not isinstance(payload['text'], str):
                raise ValueError()
            # GtkTextBuffer must not interpret escape sequences or NULs.
            return ''.join(c for c in payload['text'] if c in '\n\t' or ord(c) >= 32 and ord(c) != 127)
        except (ValueError, KeyError, TypeError):
            raise TransportError('No se pudo leer el historial. Puedes seguir usando el terminal.') from None
