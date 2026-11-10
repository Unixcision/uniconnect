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
from .mobile_protocol import RPCError
from .resume_catalog import AgentResumeCatalog
from .transport import SSHCommand, Transport, TransportError
from .vault import atomic_write, private_read
from .window_details import WindowDetails

CAPABILITY = "accounts.v1"
PROBE = Path(__file__).with_name("agent_probe.py")
MARK = "UC_ACCOUNTS_V1 "
# «Sin leer» en las fichas; «Ventanas sin IA» apagado oculta las de NO_AI.
UNREAD = ("no_legible", "desconocida", "host_inaccesible", "sesion_no_viva", "identidad_ambigua")
NO_AI = ("sin_ia", "sin_tmux", "panel_muerto")
ACCOUNT_KEYS = ("email", "method", "plan", "organization", "os_user", "config", "read_at", "usage")
HISTORY_KEEP = 14 * 86400   # Lo que se guarda.
HISTORY_SHOW = 7 * 86400    # Lo que se enseña.
HISTORY_STEP = 5 * 60       # Como mucho una muestra cada 5 min por cuenta.
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


def parse_iso(value):
    try:
        return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def last_line(text):
    """La última línea útil de lo que dijo SSH o el shell (≤ 160), sin avisos ni prompts."""
    for line in reversed((text or "").splitlines()):
        line = line.strip()
        if line and not line.lower().startswith(("warning:", "** ", "pseudo-terminal")):
            return line[:160]
    return None


class UsageHistory:
    """§3.1: lo único que se recuerda entre llamadas, y se enseña como histórico, con sus fechas."""

    def __init__(self, path):
        self.path = Path(path)

    def load(self):
        try:
            data = json.loads(private_read(self.path, maximum=4 * 1048576))
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def record(self, accounts, now):
        """Añade el uso de cada cuenta si es posterior a su última muestra; devuelve {clave: 7 días}."""
        data, changed = self.load(), False
        for account in accounts:
            usage = account.get("usage") or {}
            at = parse_iso(usage.get("observed_at"))
            limits = {item.get("id"): item.get("used_percent") for item in usage.get("limits") or []
                      if isinstance(item, dict) and item.get("id") and isinstance(item.get("used_percent"), (int, float))}
            if at is None or not limits:
                continue
            samples = [item for item in data.get(account["key"], []) if isinstance(item, dict) and parse_iso(item.get("at"))]
            last = parse_iso(samples[-1]["at"]) if samples else None
            if last is not None and at <= last:
                continue
            sample = {"at": usage["observed_at"], "limits": limits}
            if last is not None and at - last < HISTORY_STEP:
                samples[-1] = sample
            else:
                samples.append(sample)
            data[account["key"]] = samples
            changed = True
        cutoff = now - HISTORY_KEEP
        for key in list(data):
            kept = [item for item in data[key] if (parse_iso(item.get("at")) or 0) >= cutoff]
            if len(kept) != len(data[key]):
                data[key], changed = kept, True
            if not data[key]:
                del data[key]
        if changed:
            try:
                atomic_write(self.path, json.dumps(data, sort_keys=True).encode())
            except OSError:
                pass
        shown = now - HISTORY_SHOW
        return {key: [item for item in samples if (parse_iso(item.get("at")) or 0) >= shown] for key, samples in data.items()}


def driver_source():
    source = PROBE.read_text(encoding="utf-8")
    guard = 'if __name__ == "__main__":\n    sys.exit(main())\n'
    if guard not in source:
        raise RuntimeError("agent_probe.py cambió su arranque")
    return (source.replace(guard, "") + DRIVER).encode("utf-8")


class AccountsReader:
    TIMEOUT = 10       # Por host (contrato: 10 s cada sonda).
    DEADLINE = 12      # La llamada entera.

    def __init__(self, *, transport=Transport, clock=time.time, catalog=None, history=None):
        self.transport, self.clock = transport, clock
        self.catalog = catalog
        self.history = history if history is not None else UsageHistory(
            Path.home() / ".local/state/uniconnect/accounts-usage-history.json")
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
        """La sonda de un host: (estado, {socket: salida}, error, detalle) — §3 `hosts[].error`."""
        if host["kind"] == "ssh" and not host["connection"]:
            return "boveda_cerrada", None, None, None
        if not host["sockets"]:
            return "ok", {}, None, None
        requests = [[socket, sorted(sessions)] for socket, sessions in sorted(host["sockets"].items())]
        try:
            command = SSHCommand.parse(host["connection"]) if host["kind"] == "ssh" else None
        except Exception:
            return "host_inaccesible", None, "ssh_fallo", "UniConnect no puede usar la credencial SSH de esta caja"
        try:
            transport = self.transport(command, socket_name=requests[0][0])
            completed = transport.run_python(driver_source(), [json.dumps(requests)], timeout=self.TIMEOUT)
        except TransportError as error:
            if error.code == "connection_timeout":
                return "host_inaccesible", None, "sin_respuesta", None
            return "host_inaccesible", None, "ssh_fallo", (error.detail or error.code)[:160]
        except Exception as error:
            return "host_inaccesible", None, "ssh_fallo", str(error)[:160] or None
        detail = last_line(completed.stderr)
        if completed.returncode == 127 or "python3: not found" in (completed.stderr or "") \
                or "python3: command not found" in (completed.stderr or ""):
            return "host_inaccesible", None, "sin_python3", detail
        if completed.returncode == 255:
            return "host_inaccesible", None, "ssh_fallo", detail
        line = next((item for item in reversed((completed.stdout or "").splitlines()) if item.startswith(MARK)), None)
        try:
            outputs = json.loads(line[len(MARK):]) if line else None
        except ValueError:
            outputs = None
        if not isinstance(outputs, list):
            return "host_inaccesible", None, "salida_no_valida", detail or last_line(completed.stdout)
        by_socket = {item.get("socket"): item for item in outputs if isinstance(item, dict)}
        broken = [item.get("error") for item in by_socket.values() if item.get("error") in ("tmux_no_disponible", "tmux_fallo")]
        if broken and len(broken) == len(by_socket):
            return "host_inaccesible", None, broken[0], None
        return "ok", by_socket, None, None

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
                    ("host_inaccesible", None, "sin_respuesta", None), iso(self.clock()))
        response = self.build(boxes, hosts, results, checked_at=iso(self.clock()), catalog=self.catalog)
        history = self.history.record(response["accounts"], self.clock()) if self.history else {}
        for account in response["accounts"]:
            account["history"] = history.get(account["key"], [])
        return response

    @staticmethod
    def build(boxes, hosts, results, *, checked_at, catalog=None):
        """La respuesta del contrato a partir de las salidas de la sonda (pura: se prueba sin hosts)."""
        try:
            catalog = catalog or AgentResumeCatalog()
            display = catalog.display_name
        except Exception:
            display = str
        missing = (("host_inaccesible", None, "sin_respuesta", None), checked_at)
        hosts_out = []
        for key, host in sorted(hosts.items(), key=lambda pair: pair[0] != "local"):
            (state, _, error, detail), read_at = results.get(key, missing)
            hosts_out.append({"host_key": key, "label": host["label"], "kind": host["kind"], "state": state,
                              "checked_at": read_at, "error": error, "error_detail": detail})
        windows = []
        for box in boxes:
            workspace = box["workspace"]
            key = "local" if workspace["kind"] != "ssh" else "ssh:" + box["label"]
            (state, outputs, _, _), _ = results.get(key, missing)
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
        return {"version": 1, "checked_at": checked_at, "hosts": hosts_out, "windows": windows,
                "accounts": AccountsReader.accounts_of(windows, display)}

    @staticmethod
    def accounts_of(windows, display=str):
        """§3.1: una por proveedor + email, de las ventanas `ok` con email; el uso más reciente de todas."""
        accounts = {}
        for item in windows:
            account = item.get("account") or {}
            email = (account.get("email") or "").lower()
            if item["state"] != "ok" or not email or not item.get("agent"):
                continue
            provider = item["agent"]["provider"]
            entry = accounts.setdefault(provider + ":" + email, {
                "key": provider + ":" + email, "provider": provider, "display_name": display(provider), "email": email,
                "plan": None, "organization": None, "windows": 0, "host_keys": [], "usage": None, "history": []})
            entry["windows"] += 1
            entry["plan"] = entry["plan"] or account.get("plan")
            entry["organization"] = entry["organization"] or account.get("organization")
            if item["host_key"] not in entry["host_keys"]:
                entry["host_keys"].append(item["host_key"])
            usage = account.get("usage")
            if isinstance(usage, dict) and parse_iso(usage.get("observed_at")) is not None and (
                    entry["usage"] is None or parse_iso(usage["observed_at"]) > parse_iso(entry["usage"]["observed_at"])):
                entry["usage"] = dict(usage, host_key=item["host_key"])
        return sorted(accounts.values(), key=lambda entry: (-entry["windows"], entry["email"], entry["provider"]))

    def codex_reset(self, boxes, account_key, host_key, idempotency_key):
        """§5: gasta un reseteo gratis de esa cuenta de Codex en ese host. La única escritura de accounts-v1.

        Se leen las cuentas AHORA, se elige la primera ventana `ok` de esa cuenta en ese host y se lanza
        allí la sonda con ``--codex-reset``, que llama al app-server de ESE Codex y vuelve a leer su uso.
        """
        import uuid
        try:
            if (not isinstance(account_key, str) or not account_key.startswith("codex:") or len(account_key) > 330
                    or not isinstance(host_key, str) or not host_key
                    or str(uuid.UUID(str(idempotency_key))) != str(idempotency_key).lower()):
                raise ValueError()
        except ValueError:
            raise RPCError("invalid_params", "Indica la cuenta de Codex, el host y la clave de esta confirmación.") from None
        response = self.read(boxes)
        window = next((item for item in response["windows"] if item["host_key"] == host_key and item["state"] == "ok"
                       and (item.get("agent") or {}).get("provider") == "codex"
                       and "codex:" + ((item.get("account") or {}).get("email") or "").lower() == account_key.lower()), None)
        if window is None:
            raise RPCError("not_found", "No hay ninguna ventana de esa cuenta en ese host.")
        boxes = self.resolve_labels(copy.deepcopy(boxes))
        hosts = self.hosts_of(boxes)
        box = next(item for item in boxes if item["workspace"]["id"] == window["workspace_id"])
        record = next(item for item in box["windows"] if item["id"] == window["terminal_id"])
        host = hosts[host_key]
        try:
            command = SSHCommand.parse(host["connection"]) if host["kind"] == "ssh" else None
            socket_name = AgentTree.socket_of(box["workspace"], record)
            completed = self.transport(command, socket_name=socket_name).run_python(
                PROBE.read_bytes(), ["--socket", socket_name, "--session", record["tmux"],
                                     "--codex-reset", str(idempotency_key).lower()], timeout=14)
            line = next((item for item in reversed((completed.stdout or "").splitlines()) if item.startswith("{")), "")
            result = json.loads(line).get("codex_reset") or {}
        except Exception:
            result = {}
        if not result.get("outcome"):
            raise RPCError("unavailable", "El host no contestó o no hay Codex al que preguntar ({cause}).".format(
                cause=result.get("error") or "sin_respuesta"))
        return {"account_key": account_key, "host_key": host_key, "outcome": result["outcome"],
                "usage": result.get("usage")}

    @staticmethod
    def only(response, workspace_id):
        """Restringe una respuesta (compartida) a un espacio: sus ventanas y los hosts que usan."""
        if workspace_id is None:
            return response
        windows = [item for item in response["windows"] if item["workspace_id"] == workspace_id]
        keys = {item["host_key"] for item in windows}
        return dict(response, windows=windows, hosts=[item for item in response["hosts"] if item["host_key"] in keys])
