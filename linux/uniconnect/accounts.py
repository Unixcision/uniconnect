"""accounts.v1 (Dani, 10-11): con qué cuenta está cada IA, leído en vivo en cada llamada.

Cada lectura va a la fuente: la sonda compartida (`agent_probe.py --accounts`) en local y, por
SSH, una conexión por host con un plazo de 10 s, todas en paralelo. No hay caché entre llamadas:
si un host no contesta, sus ventanas salen `host_inaccesible`, nunca con la cuenta anterior. Si
llega una petición con otra lectura en curso, espera a esa y comparte su resultado.
"""

from concurrent.futures import Future, ThreadPoolExecutor, wait
import copy
import datetime
import json
from pathlib import Path
import threading
import time

from .agent_tree import AgentTree
from .arrangement import WorkspaceArrangement
from .resume_catalog import AgentResumeCatalog
from .transport import SSHCommand, Transport
from .window_details import WindowDetails

CAPABILITY = "accounts.v1"
PROBE = Path(__file__).with_name("agent_probe.py")
MARK = "UC_ACCOUNTS_V1 "
# «Sin leer» en las fichas; «Ventanas sin IA» apagado oculta las de NO_AI.
UNREAD = ("no_legible", "desconocida", "host_inaccesible", "sesion_no_viva", "identidad_ambigua")
NO_AI = ("sin_ia", "sin_tmux", "panel_muerto")
ACCOUNT_KEYS = ("email", "method", "plan", "organization", "os_user", "config", "read_at")
PALETTE = ("#EB5757", "#F2994A", "#27AE60", "#2F80ED", "#9B51E0", "#00A3A3", "#C9A227", "#E05BA8")
NEUTRAL = "#8E8E93"

# Un solo arranque por host: la sonda tal cual, más un conductor que la ejecuta para cada socket
# de ese host y devuelve todo en una línea. Las sesiones viajan como argumento, nunca un secreto.
DRIVER = '''
import json as _uc_json
_uc_out = []
for _uc_socket, _uc_sessions in _uc_json.loads(sys.argv[1]):
    try:
        _uc_out.append(probe(_uc_socket, _uc_sessions, accounts=True))
    except Exception as _uc_error:
        _uc_out.append({"version": 1, "socket": _uc_socket, "error": "sonda_fallo: " + type(_uc_error).__name__,
                        "sessions": []})
sys.stdout.write("UC_ACCOUNTS_V1 " + _uc_json.dumps(_uc_out, ensure_ascii=False, separators=(",", ":")) + "\\n")
'''


def iso(moment=None):
    value = datetime.datetime.fromtimestamp(time.time() if moment is None else moment, datetime.timezone.utc)
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def color_of(email):
    """paleta.json: FNV-1a de 32 bits sobre el email en minúsculas, mod 8; sin email, el neutro."""
    if not isinstance(email, str) or not email:
        return NEUTRAL
    value = 0x811C9DC5
    for byte in email.lower().encode("utf-8"):
        value = ((value ^ byte) * 0x01000193) & 0xFFFFFFFF
    return PALETTE[value % len(PALETTE)]


def driver_source():
    source = PROBE.read_text(encoding="utf-8")
    guard = 'if __name__ == "__main__":\n    sys.exit(main())\n'
    if guard not in source:
        raise RuntimeError("agent_probe.py cambió su arranque")
    return (source.replace(guard, "") + DRIVER).encode("utf-8")


class AccountsReader:
    TIMEOUT = 10       # Por host (contrato: 10 s cada sonda).
    DEADLINE = 12      # La llamada entera.

    def __init__(self, *, transport=Transport, clock=time.time, catalog=None):
        self.transport, self.clock = transport, clock
        self.catalog = catalog
        self.lock = threading.Lock()
        self.inflight = None

    # ----- en el hilo de GTK -----
    @staticmethod
    def snapshot(window):
        """Lo que hace falta leer, copiado en el hilo dueño del modelo: espacios, ventanas y conexiones."""
        vault = getattr(window, "vault", None)
        boxes = []
        for workspace in WorkspaceArrangement.ordered(window.store.workspaces):
            connection = None
            if workspace["kind"] == "ssh" and vault is not None and not vault.locked:
                try:
                    connection = window.connection(workspace)
                except Exception:
                    connection = None
            # El destino efectivo (ssh -G) se resuelve fuera de GTK, en resolve_labels.
            label = (WindowDetails.host_label(workspace.get("hostLabel")) or workspace.get("name") or workspace["id"]
                     if workspace["kind"] == "ssh" else None)
            boxes.append({"workspace": copy.deepcopy({key: value for key, value in workspace.items() if key != "windows"}),
                          "windows": copy.deepcopy(WorkspaceArrangement.ordered(workspace.get("windows", []))),
                          "connection": connection, "label": label})
        return boxes

    # ----- fuera de GTK -----
    def read(self, boxes):
        """Una lectura en vivo; si ya hay una en curso, se espera a esa y se comparte su resultado."""
        with self.lock:
            shared = self.inflight
            if shared is None:
                self.inflight = mine = Future()
        if shared is not None:
            return copy.deepcopy(shared.result(timeout=self.DEADLINE + 5))
        try:
            result = self.collect(boxes)
            mine.set_result(result)
            return copy.deepcopy(result)
        except BaseException as error:
            mine.set_exception(error)
            raise
        finally:
            with self.lock:
                self.inflight = None

    @staticmethod
    def hosts_of(boxes):
        """host_key → {label, kind, connection, sockets: {socket: {sesiones}}}, en el orden de la barra."""
        hosts = {}
        for box in boxes:
            workspace = box["workspace"]
            key = "local" if workspace["kind"] != "ssh" else "ssh:" + box["label"]
            host = hosts.setdefault(key, {"label": "Este equipo" if key == "local" else box["label"],
                                          "kind": "local" if key == "local" else "ssh",
                                          "connection": None, "sockets": {}})
            if key != "local" and host["connection"] is None:
                host["connection"] = box["connection"]
            for record in box["windows"]:
                if record.get("tmux"):
                    host["sockets"].setdefault(AgentTree.socket_of(workspace, record), set()).add(record["tmux"])
        return hosts

    def run_host(self, key, host):
        """La sonda de un host: {socket: salida} o la causa por la que no se pudo leer."""
        if host["kind"] == "ssh" and not host["connection"]:
            return "boveda_cerrada", None
        if not host["sockets"]:
            return "ok", {}
        requests = [[socket, sorted(sessions)] for socket, sessions in sorted(host["sockets"].items())]
        try:
            command = SSHCommand.parse(host["connection"]) if host["kind"] == "ssh" else None
            transport = self.transport(command, socket_name=requests[0][0])
            completed = transport.run_python(driver_source(), [json.dumps(requests)], timeout=self.TIMEOUT)
        except Exception:
            return "host_inaccesible", None
        line = next((item for item in reversed((completed.stdout or "").splitlines()) if item.startswith(MARK)), None)
        if completed.returncode != 0 or line is None:
            return "host_inaccesible", None  # No contestó, venció el plazo o falta python3.
        try:
            outputs = json.loads(line[len(MARK):])
        except ValueError:
            return "host_inaccesible", None
        return "ok", {item.get("socket"): item for item in outputs if isinstance(item, dict)}

    @staticmethod
    def resolve_labels(boxes):
        """``usuario@host:puerto`` del destino efectivo, como en los Detalles (``ssh -G``, fuera de GTK)."""
        for box in boxes:
            if box["workspace"]["kind"] == "ssh" and box["connection"]:
                try:
                    box["label"] = WindowDetails.endpoint_label(*SSHCommand.parse(box["connection"]).endpoint_key())
                except Exception:
                    pass
        return boxes

    def collect(self, boxes):
        boxes = self.resolve_labels(copy.deepcopy(boxes))
        hosts = self.hosts_of(boxes)
        results = {}
        with ThreadPoolExecutor(max_workers=max(1, min(8, len(hosts)))) as pool:
            futures = {pool.submit(self.run_host, key, host): key for key, host in hosts.items()}
            done, _ = wait(futures, timeout=self.DEADLINE)
            for future, key in futures.items():
                results[key] = (future.result(), iso(self.clock())) if future in done else (
                    ("host_inaccesible", None), iso(self.clock()))
        return self.build(boxes, hosts, results, checked_at=iso(self.clock()), catalog=self.catalog)

    @staticmethod
    def build(boxes, hosts, results, *, checked_at, catalog=None):
        """La respuesta del contrato a partir de las salidas de la sonda (pura: se prueba sin hosts)."""
        try:
            catalog = catalog or AgentResumeCatalog()
            display = catalog.display_name
        except Exception:
            display = str
        hosts_out = []
        for key, host in hosts.items():
            (state, _), read_at = results.get(key, (("host_inaccesible", None), checked_at))
            hosts_out.append({"host_key": key, "label": host["label"], "kind": host["kind"], "state": state,
                              "checked_at": read_at})
        windows = []
        for box in boxes:
            workspace = box["workspace"]
            key = "local" if workspace["kind"] != "ssh" else "ssh:" + box["label"]
            (state, outputs), _ = results.get(key, (("host_inaccesible", None), checked_at))
            for record in box["windows"]:
                entry = {"workspace_id": workspace["id"], "workspace": workspace.get("name"),
                         "terminal_id": record["id"], "window": record.get("name"), "host_key": key,
                         "tmux_session": record.get("tmux"), "state": None, "agent": None, "account": None}
                windows.append(entry)
                if state != "ok":
                    entry["state"] = "host_inaccesible"
                    continue
                if not record.get("tmux"):
                    entry["state"] = "sin_tmux"
                    continue
                output = (outputs or {}).get(AgentTree.socket_of(workspace, record)) or {}
                session = next((item for item in output.get("sessions", [])
                                if isinstance(item, dict) and item.get("name") == record["tmux"]), None)
                if session is None:
                    entry["state"] = "sesion_no_viva"
                    continue
                if session.get("reason") in ("sin_ia", "identidad_ambigua", "panel_muerto"):
                    entry["state"] = session["reason"]
                    continue
                agent = session.get("agent")
                if not isinstance(agent, dict) or not agent.get("provider"):
                    entry["state"] = "sin_ia"
                    continue
                account = agent.get("account") if isinstance(agent.get("account"), dict) else {}
                entry["agent"] = {"provider": agent["provider"], "display_name": display(agent["provider"]),
                                  "as_root": bool(agent.get("as_root"))}
                entry["state"] = account.get("state") or "desconocida"
                entry["account"] = {name: account.get(name) for name in ACCOUNT_KEYS}
        return {"version": 1, "checked_at": checked_at, "hosts": hosts_out, "windows": windows}

    @staticmethod
    def only(response, workspace_id):
        """Restringe una respuesta (compartida) a un espacio: sus ventanas y los hosts que usan."""
        if workspace_id is None:
            return response
        windows = [item for item in response["windows"] if item["workspace_id"] == workspace_id]
        keys = {item["host_key"] for item in windows}
        return dict(response, windows=windows, hosts=[item for item in response["hosts"] if item["host_key"] in keys])
