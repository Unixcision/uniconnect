"""Rearmar la reconexión SSH cuando vuelve el servidor (contrato ssh-server-return.v1).

Cuando una ventana SSH agota sus reintentos automáticos, se comprueba cada 30 s si el puerto
SSH del servidor contesta (solo TCP: sin iniciar sesión ni enviar credenciales). La política
decide tras cada comprobación; es la misma que ``UniConnectSSHServerReturnPolicy`` del Mac y
ambas se prueban contra ``contracts/ssh-server-return-v1/casos.json``.
"""

REARM = "rearmar"
KEEP_WAITING = "esperar"
STOP = "parar"

CHECK_INTERVAL_SECONDS = 30
PROBE_TIMEOUT_SECONDS = 5


class ServerReturnPolicy:
    """Estado de una ventana entre comprobaciones; se conserva entre esperas."""

    def __init__(self):
        self._saw_server_down = False
        self._used_answering_retry = False

    def observe(self, server_answers):
        """Devuelve ``rearmar``, ``esperar`` o ``parar`` para una comprobación."""
        if not server_answers:
            self._saw_server_down = True
            return KEEP_WAITING
        if self._saw_server_down:
            self._saw_server_down = False
            return REARM
        if not self._used_answering_retry:
            self._used_answering_retry = True
            return REARM
        return STOP


def probe_ssh_port(host, port, timeout, done):
    """Intenta una conexión TCP a ``host:port`` y llama a ``done(bool)`` en el bucle de GLib."""
    from gi.repository import Gio, GLib

    client = Gio.SocketClient.new()
    client.set_timeout(max(1, int(timeout)))

    def finished(source, result):
        try:
            connection = source.connect_finish(result)
        except GLib.Error:
            done(False)
            return
        try:
            connection.close(None)
        except GLib.Error:
            pass
        done(True)

    try:
        address = Gio.NetworkAddress.new(str(host), int(port))
    except (TypeError, ValueError):
        done(False)
        return
    client.connect_async(address, None, finished)
