"""Sonda de solo lectura del árbol IA (agent-tree.v1): qué IA corre en cada sesión tmux.

Es un script autónomo (solo biblioteca estándar, compatible con Python 3.6) que se
ejecuta en el propio host: en local, por el mismo canal SSH de la caja (por stdin con
``python3 -`` o con el arranque ``python3 -c 'import base64,sys;...' <b64>``) o
importado desde los tests. El Mac lo empaqueta tal cual; la salida la fija
contracts/agent-tree-v1/sonda-salida.json.

Criterio (contracts/agent-tree-v1/deteccion-casos.json):
- ``#{pane_pid}`` es el shell del panel, no la IA. Se recorre su subárbol en anchura
  sobre la tabla de procesos (profundidad <= 8, <= 256 nodos). Nunca ``pgrep -P`` ni
  el entorno heredado: solo cuenta lo que desciende del panel.
- Raíz = proceso de un proveedor sin ningún antepasado de proveedor dentro del
  subárbol. 0 raíces -> ``sin_ia``; 2 o más -> ``identidad_ambigua``; 1 -> esa IA.
- Identidad: Claude por su ficha ``<config>/sessions/<pid>.json`` (``ficha``) o por
  argv (``argv``, puede estar desfasado); Codex por el rollout abierto (``rollout``)
  o por ``resume <uuid>``; agy por ``--conversation``; grok por ``-r``/``--resume``.
- Ante la duda no se da id (decisiones del 24-09): tras ``--`` no hay opciones, dos ids
  distintos en argv dan ``sin_id``, con varios rollouts abiertos solo vale el que coincide
  con ``resume <uuid>`` y la ficha nunca clasifica a un proceso como Claude.

Nunca escribe, nunca envía teclas ni cambia opciones de tmux y nunca usa sudo.

CLI: ``[--socket NOMBRE|default] [--session NOMBRE]...`` (``default`` no pasa ``-L``).
Sale siempre con 0 e imprime una línea JSON (<= 256 KB); el mal uso sale con 2:

    {"version": 1, "checked_at": "2026-09-24T14:30:04Z", "socket": "default",
     "host": {"hostname": "...", "uid": 0, "platform": "linux"},
     "server": true, "error": null, "truncated": false,
     "sessions": [{"name": "claudebets", "session_id": "$0", "pane_id": "%0", "pane_pid": 123,
                   "live": true, "reason": null | "sin_ia" | "identidad_ambigua" | "sin_id" | "panel_muerto",
                   "agent": null | {"provider": "claude", "session_id": "...", "cwd": "/root/xunis",
                                    "as_root": true, "source": "ficha", "pid": 456, "status": "idle",
                                    "version": "2.1.280", "proc_start": "..."},
                   "panes": [{"pane_id": "%0", "window_index": 0, "pane_pid": 123, "dead": false,
                              "current_path": "/root", "current_command": "claude"}]}]}

``server: false`` sin error significa que ese servidor tmux no tiene sesiones.
"""

import datetime
import json
import os
import pwd
import re
import socket as socket_module
import subprocess
import sys
import time

VERSION = 1
MAX_PROCESSES = 4096
MAX_PANES = 2048
MAX_DEPTH = 8
MAX_NODES = 256
MAX_OUTPUT = 256 * 1024
MAX_FICHA = 64 * 1024
MAX_FIRST_LINE = 64 * 1024

SESSION_ID = re.compile(r"[A-Za-z0-9_-]{1,160}\Z")
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
NODE = re.compile(r"(node|nodejs|bun)(\d+(\.\d+)*)?\Z")
ROLLOUT = re.compile(r"rollout-.*-(" + UUID.pattern + r")\.jsonl\Z")
SOCKET_NAME = re.compile(r"[A-Za-z0-9_.-]{1,64}\Z")
TMUX_NAME = re.compile(r"[^\t\n\r\0]{1,256}\Z")
TMUX_FORMAT = "\t".join(("#{session_name}", "#{session_id}", "#{window_index}", "#{pane_id}", "#{pane_pid}",
                          "#{pane_dead}", "#{pane_current_path}", "#{pane_current_command}"))
# Lanzadores y shells: no son IA; sus descendientes ya están en el subárbol.
NOT_AGENTS = frozenset(("sudo", "doas", "env", "sh", "bash", "zsh", "fish", "dash", "ksh", "login", "tmux",
                        "script", "nohup", "timeout", "stdbuf", "nice", "setsid", "python", "python3"))
SEARCH_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"


def basename(value):
    return os.path.basename(value or "").lstrip("-")


def canonical_id(value):
    """Valida un id de conversación; los UUID van siempre en minúsculas."""
    if not isinstance(value, str) or not SESSION_ID.match(value):
        return None
    return value.lower() if UUID.fullmatch(value) else value


def provider_of(argv):
    """Proveedor canónico de un proceso por su línea de órdenes, o None.

    Criterio estricto (regla 2 del contrato): la ficha nunca clasifica; un argumento que
    solo contiene «claude» (``vim ~/.claude/CLAUDE.md``) no hace Claude a nadie.
    """
    if not argv:
        return None
    first = argv[0]
    base = basename(first)
    if base in NOT_AGENTS or re.match(r"python\d", base):
        return None
    if base == "claude" or "/claude/versions/" in first:
        return "claude"
    if base.startswith("codex"):
        return "codex"
    if base in ("agy", "antigravity"):
        return "agy"
    if base == "grok" or base.startswith("grok-"):
        return "grok"
    if NODE.match(base):
        for argument in argv[1:]:
            # Claude de npm lanzado por su shebang: ``node /opt/homebrew/bin/claude``.
            if "@anthropic-ai/claude-code" in argument or os.path.basename(argument) == "claude":
                return "claude"
            if "@openai/codex" in argument or os.path.basename(argument) in ("codex", "codex.js"):
                return "codex"
    return None


def option_value(argv, names, valid):
    """El único valor de las opciones ``names`` en argv, o None.

    - Solo cuenta lo que va antes del primer ``--``: lo de detrás es texto para la IA.
    - ``--x v``: el valor es el token siguiente, salvo que empiece por ``-``.
    - ``--x=v``: solo en opciones largas (``-r=…`` no es una forma válida).
    - Un valor que no cumple ``valid`` o dos valores distintos (los UUID, en minúsculas)
      anulan la línea de órdenes como fuente: ante la duda no se da id.
    """
    values, index = set(), 1
    while index < len(argv):
        argument = argv[index]
        if argument == "--":
            break
        value = None
        if argument in names:
            if index + 1 < len(argv) and not argv[index + 1].startswith("-"):
                value = argv[index + 1]
                index += 1
        else:
            for name in names:
                if name.startswith("--") and argument.startswith(name + "="):
                    value = argument[len(name) + 1:]
        if value is not None:
            if not valid(value):
                return None
            values.add(canonical_id(value))
        index += 1
    return values.pop() if len(values) == 1 else None


def is_claude_id(value):
    return bool(UUID.fullmatch(value))


def is_session_id(value):
    return canonical_id(value) is not None


def codex_resume_argument(argv):
    """El UUID que sigue al primer ``resume`` antes de ``--``, o None."""
    for index, argument in enumerate(argv[1:], 1):
        if argument == "--":
            return None
        if argument == "resume":
            following = argv[index + 1] if index + 1 < len(argv) else ""
            return following.lower() if UUID.fullmatch(following) else None
    return None


def subtree(pane_pid, processes):
    """Descendientes de pane_pid (incluido) en anchura, con sus padres dentro del subárbol."""
    children = {}
    for process in processes.values():
        children.setdefault(process["ppid"], []).append(process["pid"])
    if pane_pid not in processes:
        return [], {}
    order, parent, frontier = [pane_pid], {pane_pid: None}, [pane_pid]
    for _ in range(MAX_DEPTH):
        following = []
        for pid in frontier:
            for child in sorted(children.get(pid, ())):
                if child in parent or len(order) >= MAX_NODES:
                    continue
                parent[child] = pid
                order.append(child)
                following.append(child)
        frontier = following
        if not frontier:
            break
    return order, parent


def discover(pane_pid, procesos, ficha_de, abiertos_de, primera_linea_de, cwd_de_reserva, *,
             pane_path=None, realpath=None):
    """Núcleo puro: la IA de un panel a partir de sus tablas.

    - ``procesos``: {pid: {"pid", "ppid", "uid", "argv"}} o una lista de esos dicts.
    - ``ficha_de(pid, uid)``: la ficha de Claude de ese pid (dict) o None.
    - ``abiertos_de(pid)``: rutas de los ficheros abiertos por ese pid.
    - ``primera_linea_de(ruta)``: primera línea (texto) de un rollout de Codex, o None.
    - ``cwd_de_reserva(pid)``: carpeta actual del proceso, o None.

    Devuelve {"reason": None|"sin_ia"|"identidad_ambigua"|"sin_id", "agent": dict|None,
    "roots": [pid, ...]}.
    """
    if not isinstance(procesos, dict):
        procesos = {int(item["pid"]): item for item in procesos}
    realpath = realpath or (lambda value: value)
    order, parent = subtree(pane_pid, procesos)
    if not order:
        # El shell del panel ya no existe (o la tabla se recortó): no se sabe nada.
        return {"reason": "panel_muerto", "agent": None, "roots": []}
    kinds = {pid: provider_of(procesos[pid].get("argv") or []) for pid in order}
    roots = []
    for pid in order:
        if not kinds[pid]:
            continue
        ancestor, nested = parent[pid], False
        while ancestor is not None:
            if kinds.get(ancestor):
                nested = True
                break
            ancestor = parent.get(ancestor)
        if not nested:
            roots.append(pid)
    if not roots:
        return {"reason": "sin_ia", "agent": None, "roots": []}
    if len(roots) > 1:
        return {"reason": "identidad_ambigua", "agent": None, "roots": roots}
    root = roots[0]
    process = procesos[root]
    provider, argv, uid = kinds[root], process.get("argv") or [], int(process.get("uid", -1))
    agent = {"provider": provider, "session_id": None, "cwd": None, "as_root": uid == 0, "source": None,
             "pid": root, "status": None, "version": None, "proc_start": None}
    if provider == "claude":
        ficha = ficha_de(root, uid)
        session = canonical_id(ficha.get("sessionId")) if isinstance(ficha, dict) else None
        if session and ficha.get("pid") in (None, root, str(root)):
            agent.update(session_id=session, source="ficha", cwd=ficha.get("cwd") if isinstance(ficha.get("cwd"), str) else None,
                         status=ficha.get("status"), version=ficha.get("version"), proc_start=ficha.get("procStart"))
        else:
            value = option_value(argv, ("--resume", "-r", "--session-id"), is_claude_id)
            if value:
                agent.update(session_id=value, source="argv")
    elif provider == "codex":
        branch = [pid for pid in order if kinds[pid] == "codex" and _descends(pid, root, parent)]
        found = {}
        for pid in branch:
            for path in abiertos_de(pid) or ():
                match = ROLLOUT.search(path or "")
                if match and "/.codex/sessions/" in path:
                    found.setdefault(match.group(1).lower(), path)
        resumed = next((value for value in (codex_resume_argument(procesos[pid].get("argv") or []) for pid in branch)
                        if value), None)
        chosen = None
        if len(found) == 1:
            chosen = next(iter(found))
        elif len(found) > 1 and resumed in found:
            # Un ``codex exec`` de la propia sesión abre su rollout, más reciente: solo vale el suyo.
            chosen = resumed
        if chosen:
            agent.update(session_id=chosen, source="rollout")
            try:
                line = primera_linea_de(found[chosen])
                payload = json.loads(line).get("payload", {}) if line else {}
                if isinstance(payload, dict) and isinstance(payload.get("cwd"), str):
                    agent["cwd"] = payload["cwd"]
            except (ValueError, AttributeError, TypeError):
                pass
        elif not found and resumed:
            agent.update(session_id=resumed, source="argv")
    elif provider == "agy":
        value = option_value(argv, ("--conversation",), is_session_id)
        if value:
            agent.update(session_id=value, source="argv")
    elif provider == "grok":
        value = option_value(argv, ("-r", "--resume"), is_session_id)
        if value:
            agent.update(session_id=value, source="argv")
    if not agent["cwd"]:
        agent["cwd"] = cwd_de_reserva(root) or pane_path
    if isinstance(agent["cwd"], str) and agent["cwd"].startswith("/"):
        agent["cwd"] = realpath(agent["cwd"])
    else:
        agent["cwd"] = None
    return {"reason": None if agent["session_id"] else "sin_id", "agent": agent, "roots": roots}


def _descends(pid, root, parent):
    while pid is not None:
        if pid == root:
            return True
        pid = parent.get(pid)
    return False


def combine(panes):
    """Una sesión con varios paneles cuenta el único panel con raíz de IA.

    ``panes``: lista de (panel, resultado). Devuelve (panel elegido, resultado).
    """
    alive = [(pane, result) for pane, result in panes
             if not pane.get("dead") and result["reason"] != "panel_muerto"]
    if not alive:
        pane = panes[0][0] if panes else None
        return pane, {"reason": "panel_muerto", "agent": None, "roots": []}
    with_root = [(pane, result) for pane, result in alive if result["roots"]]
    if not with_root:
        return alive[0][0], {"reason": "sin_ia", "agent": None, "roots": []}
    if len(with_root) > 1:
        return with_root[0][0], {"reason": "identidad_ambigua", "agent": None,
                                 "roots": [pid for _, result in with_root for pid in result["roots"]]}
    return with_root[0]


class HostReader:
    """Lectores reales del host (solo lectura). Linux usa /proc; macOS, ps y lsof."""

    def __init__(self):
        self.proc = os.path.isdir("/proc/self/fd")
        self.environment = dict(os.environ)
        self.environment["PATH"] = SEARCH_PATH + ":" + self.environment.get("PATH", "")
        self.truncated = False
        config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
        self.own_sessions = os.path.join(config, "sessions")

    def run(self, argv, timeout=5):
        try:
            result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
                                    env=self.environment, universal_newlines=True)
        except (OSError, subprocess.SubprocessError):
            return None
        return result

    def processes(self):
        table = {}
        if self.proc:
            for name in os.listdir("/proc"):
                if not name.isdigit():
                    continue
                if len(table) >= MAX_PROCESSES:
                    self.truncated = True
                    break
                pid = int(name)
                try:
                    with open("/proc/%d/stat" % pid, "rb") as handle:
                        fields = handle.read().decode("utf-8", "replace").rsplit(")", 1)[1].split()
                    with open("/proc/%d/cmdline" % pid, "rb") as handle:
                        raw = handle.read(65536)
                    uid = os.stat("/proc/%d" % pid).st_uid
                except (OSError, IndexError):
                    continue
                argv = [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]
                table[pid] = {"pid": pid, "ppid": int(fields[1]), "uid": uid, "argv": argv}
            return table
        result = self.run(["ps", "-A", "-ww", "-o", "pid=,ppid=,uid=,args="])
        for line in (result.stdout if result and result.returncode == 0 else "").splitlines():
            parts = line.split(None, 3)
            if len(parts) < 3 or not parts[0].isdigit() or not parts[1].isdigit():
                continue
            if len(table) >= MAX_PROCESSES:
                self.truncated = True
                break
            try:
                uid = int(parts[2])
            except ValueError:
                continue
            table[int(parts[0])] = {"pid": int(parts[0]), "ppid": int(parts[1]), "uid": uid,
                                    "argv": parts[3].split() if len(parts) > 3 else []}
        return table

    def ficha(self, pid, uid):
        directories = [self.own_sessions]
        try:
            home = pwd.getpwuid(uid).pw_dir
            directories.append(os.path.join(home, ".claude", "sessions"))
        except (KeyError, OverflowError, TypeError):
            pass
        for directory in dict.fromkeys(directories):
            path = os.path.join(directory, "%d.json" % pid)
            try:
                with open(path, "rb") as handle:
                    raw = handle.read(MAX_FICHA + 1)
            except OSError:
                continue
            if len(raw) > MAX_FICHA:
                continue
            try:
                value = json.loads(raw.decode("utf-8"))
            except ValueError:
                continue
            if isinstance(value, dict):
                return value
        return None

    def open_files(self, pid):
        if self.proc:
            paths = []
            try:
                descriptors = os.listdir("/proc/%d/fd" % pid)
            except OSError:
                return paths
            for descriptor in descriptors[:4096]:
                try:
                    paths.append(os.readlink("/proc/%d/fd/%s" % (pid, descriptor)))
                except OSError:
                    continue
            return paths
        result = self.run(["lsof", "-n", "-P", "-p", str(pid), "-Fn"])
        return [line[1:] for line in (result.stdout if result else "").splitlines() if line.startswith("n")]

    def cwd(self, pid):
        if self.proc:
            try:
                return os.readlink("/proc/%d/cwd" % pid)
            except OSError:
                return None
        result = self.run(["lsof", "-a", "-n", "-P", "-p", str(pid), "-d", "cwd", "-Fn"])
        for line in (result.stdout if result else "").splitlines():
            if line.startswith("n/"):
                return line[1:]
        return None

    @staticmethod
    def first_line(path):
        try:
            with open(path, "rb") as handle:
                return handle.readline(MAX_FIRST_LINE).decode("utf-8", "replace")
        except OSError:
            return None

    @staticmethod
    def realpath(path):
        return os.path.realpath(path)

    @staticmethod
    def host():
        """Quién sondea: ``{hostname, uid, platform}`` (``uid`` 0 = root)."""
        return {"hostname": socket_module.gethostname(), "uid": os.geteuid(), "platform": sys.platform}

    def panes(self, socket_name):
        """(paneles, error). Sin servidor tmux no es un error: no hay sesiones."""
        argv = ["tmux"] + ([] if socket_name == "default" else ["-L", socket_name]) + [
            "list-panes", "-a", "-F", TMUX_FORMAT]
        result = self.run(argv, timeout=5)
        if result is None:
            return [], "tmux_no_disponible"
        if result.returncode != 0:
            error = (result.stderr or "").lower()
            if "no server running" in error or "error connecting" in error or "no such file" in error:
                return [], None
            return [], "tmux_fallo"
        panes = []
        for line in result.stdout.splitlines():
            fields = line.split("\t", 7)
            if len(fields) != 8 or not fields[4].isdigit():
                continue
            if len(panes) >= MAX_PANES:
                self.truncated = True
                break
            panes.append({"session": fields[0], "session_id": fields[1],
                          "window_index": int(fields[2]) if fields[2].isdigit() else None,
                          "pane_id": fields[3], "pane_pid": int(fields[4]), "dead": fields[5] == "1",
                          "current_path": fields[6] or None, "current_command": fields[7] or None})
        return panes, None


def iso_now(now=None):
    moment = datetime.datetime.utcfromtimestamp(now if now is not None else time.time())
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def probe(socket_name="default", sessions=(), reader=None, now=None):
    """Lee el host y devuelve el JSON v1 (dict) de contracts/agent-tree-v1/sonda-salida.json."""
    reader = reader or HostReader()
    host = reader.host() if hasattr(reader, "host") else HostReader.host()
    output = {"version": VERSION, "checked_at": iso_now(now), "socket": socket_name, "host": host,
              "server": True, "error": None, "truncated": False, "sessions": []}
    panes, error = reader.panes(socket_name)
    if error:
        output.update(error=error, server=False)
        return output
    if not panes:
        output["server"] = False
        return output
    wanted = set(sessions)
    grouped = {}
    for pane in panes:
        if wanted and pane["session"] not in wanted:
            continue
        grouped.setdefault(pane["session"], []).append(pane)
    table = reader.processes() if grouped else {}
    for name, members in grouped.items():
        results = []
        for pane in members:
            result = discover(pane["pane_pid"], table, reader.ficha, reader.open_files, reader.first_line,
                              reader.cwd, pane_path=pane["current_path"], realpath=reader.realpath)
            results.append((pane, result))
        chosen, result = combine(results)
        output["sessions"].append({
            "name": name, "session_id": members[0]["session_id"],
            "pane_id": chosen["pane_id"] if chosen else None,
            "pane_pid": chosen["pane_pid"] if chosen else None,
            "live": True, "reason": result["reason"], "agent": result["agent"],
            "panes": [{key: pane[key] for key in ("pane_id", "window_index", "pane_pid", "dead",
                                                   "current_path", "current_command")} for pane in members]})
    output["truncated"] = bool(reader.truncated)
    return output


def encode(output):
    """JSON compacto de como mucho MAX_OUTPUT bytes; si no cabe, se recorta y se marca."""
    data = json.dumps(output, ensure_ascii=False, separators=(",", ":"))
    if len(data.encode("utf-8")) <= MAX_OUTPUT:
        return data
    output = dict(output, truncated=True, sessions=[dict(item, panes=[]) for item in output["sessions"]])
    while output["sessions"]:
        data = json.dumps(output, ensure_ascii=False, separators=(",", ":"))
        if len(data.encode("utf-8")) <= MAX_OUTPUT:
            return data
        output["sessions"].pop()
    return json.dumps(output, ensure_ascii=False, separators=(",", ":"))


def parse_arguments(arguments):
    """CLI: ``[--socket NOMBRE|default] [--session NOMBRE]...``. Devuelve (socket, sesiones) o None."""
    socket_name, sessions, index = "default", [], 0
    while index < len(arguments):
        option = arguments[index]
        if option in ("--socket", "--session") and index + 1 < len(arguments):
            value = arguments[index + 1]
            if option == "--socket":
                if not SOCKET_NAME.match(value):
                    return None
                socket_name = value
            else:
                if not TMUX_NAME.match(value):
                    return None
                sessions.append(value)
            index += 2
            continue
        return None
    return socket_name, sessions


def main(arguments=None, reader=None, stdout=None, now=None):
    stdout = stdout or sys.stdout
    parsed = parse_arguments(sys.argv[1:] if arguments is None else list(arguments))
    if parsed is None:
        sys.stderr.write("uso: agent_probe.py [--socket NOMBRE|default] [--session NOMBRE]...\n")
        return 2
    socket_name, sessions = parsed
    try:
        output = probe(socket_name, sessions, reader=reader, now=now)
    except Exception as error:  # La sonda nunca falla con traza: el error viaja en el JSON.
        output = {"version": VERSION, "checked_at": iso_now(now), "socket": socket_name, "host": None,
                  "server": False, "error": "sonda_fallo: " + type(error).__name__, "truncated": False,
                  "sessions": []}
    stdout.write(encode(output) + "\n")
    stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
