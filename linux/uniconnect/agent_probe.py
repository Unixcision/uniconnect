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
  argv (``argv``, puede estar desfasado); Codex por el rollout abierto (``rollout``),
  por ``resume <uuid>`` o, sin ninguno de los dos (Codex 0.166+, que ya no deja el rollout
  abierto), por su tabla ``threads`` de ``$CODEX_HOME/state_<n>.sqlite`` (``threads``, solo
  lectura): el hilo de ``codex-tui`` de su carpeta creado tras arrancar (5 s de margen), el que
  cambió más tarde, y nunca si otro Codex vivo de esa carpeta arrancó a tiempo de ser su dueño;
  agy por ``--conversation``; grok por ``-r``/``--resume``.
- Ante la duda no se da id (decisiones del 24-09): tras ``--`` no hay opciones, dos ids
  distintos en argv dan ``sin_id``, con varios rollouts abiertos solo vale el que coincide
  con ``resume <uuid>`` y la ficha nunca clasifica a un proceso como Claude.

Nunca escribe, nunca envía teclas ni cambia opciones de tmux y nunca usa sudo. La única excepción
es ``--codex-reset CLAVE`` (accounts-v1 §5): gasta un reseteo gratis de la cuenta del Codex de la
única sesión pedida, a través de su propio app-server, y solo cuando alguien lo ha confirmado.

CLI: ``[--socket NOMBRE|default] [--session NOMBRE]... [--accounts]`` (``default`` no pasa ``-L``).

Con ``--accounts`` (contracts/accounts-v1) cada ``agent`` lleva además ``account``: la cuenta con
la que está esa IA, leída en este momento de sus ficheros (``.claude.json``, ``.codex/auth.json``)
según el entorno del propio proceso (``CLAUDE_CONFIG_DIR``, ``CODEX_HOME``, ``HOME``). Nada se
guarda entre llamadas; de los secretos solo se mira si existen, y jamás salen de aquí.
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

import base64
import binascii
import datetime
import hashlib
import heapq
import json
import os
import pwd
import re
import select
import signal
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
# accounts-v1: del entorno de la IA solo salen estas rutas; de los secretos, solo si están puestos.
ACCOUNT_ENV_PATHS = ("HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME")
ACCOUNT_ENV_FLAGS = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                     "CLAUDE_CODE_USE_FOUNDRY", "OPENAI_API_KEY")
# Token de «claude setup-token» (p. ej. el alias claude-kin): de él solo sale su huella, los 16 primeros
# hex de su SHA-256, la misma que calcula la barra de estado para buscarlo en ~/.claude/cuentas-token.
ACCOUNT_ENV_TOKEN = "CLAUDE_CODE_OAUTH_TOKEN"
MAX_TOKEN_MAP = 64 * 1024
MAX_ACCOUNT_FILE = 64 * 1024 * 1024
CLAUDE_PLANS = {"claude_max": "Max", "claude_pro": "Pro", "claude_team": "Team", "claude_enterprise": "Enterprise"}


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


# relaunch-v1 «Mismas opciones» (08-11): lo único que se guarda de cómo se lanzó una IA
# (opciones con valor, interruptores). Sin prompts, sin --system-prompt, sin -c con secretos.
LAUNCH_OPTIONS = {
    "claude": (frozenset(("--model", "--effort", "--fallback-model", "--permission-mode", "--settings", "--setting-sources",
                          "--add-dir", "--allowedTools", "--disallowedTools", "--mcp-config", "--tools")),
               frozenset(("--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--verbose",
                          "--strict-mcp-config", "--chrome"))),
    "codex": (frozenset(("-c", "--config", "-m", "--model", "-C", "--cd", "-s", "--sandbox", "-a",
                         "--ask-for-approval", "-p", "--profile", "--add-dir", "--enable", "--disable")),
              frozenset(("--no-alt-screen", "--search", "--full-auto", "--dangerously-bypass-approvals-and-sandbox",
                         "--yolo"))),
    "agy": (frozenset(("--model", "--effort", "--mode", "--project", "--agent", "--add-dir")),
            frozenset(("--sandbox", "--remote-control", "--dangerously-skip-permissions"))),
}
LAUNCH_SELECTORS = {"claude": ("--resume", "-r", "--session-id"), "agy": ("--conversation",), "codex": ()}
SECRET_CONFIG = re.compile(r"key|token|secret|password|auth", re.IGNORECASE)


def launch_options(provider, argv):
    """Las opciones permitidas con que se lanzó la IA, en su orden, o None si el proveedor no tiene.

    Fuera: el selector de conversación (se reanuda por id), --continue/--last, prompts y
    cualquier opción desconocida con su valor, ``-c`` con claves de secretos y los ganchos que
    UniConnect monta en cada arranque (``notify`` de Codex o ``--settings`` con su puente).
    """
    if provider not in LAUNCH_OPTIONS or not argv:
        return None
    values, switches = LAUNCH_OPTIONS[provider]
    arguments = list(argv[1:])
    if NODE.match(basename(argv[0])) and arguments:
        arguments = arguments[1:]  # ``node /usr/bin/codex …``: el primero es el script.
    kept, index, resumed = [], 0, False
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            break
        option = argument.split("=", 1)[0]
        following = arguments[index + 1] if index + 1 < len(arguments) else None
        if provider == "codex" and not resumed and argument == "resume":
            resumed = True
            index += 2 if following is not None and not following.startswith("-") else 1
            continue
        if option in LAUNCH_SELECTORS[provider]:
            index += 1 if "=" in argument else 2
            continue
        if argument in ("--continue", "--last", "--all") or (provider == "claude" and argument == "-c"):
            index += 1
            continue
        if option in values:
            inline = "=" in argument
            value = argument.split("=", 1)[1] if inline else following
            if value is None:
                break
            managed = "uniconnect" in value.lower() or "UNICONNECT_NATIVE_HELPER" in value
            secret = option in ("-c", "--config") and SECRET_CONFIG.search(value.split("=", 1)[0])
            if not managed and not secret:
                kept.extend([argument] if inline else [argument, value])
            index += 1 if inline else 2
            continue
        if argument in switches:
            if argument not in kept:
                kept.append(argument)
            index += 1
            continue
        # Desconocida o un prompt: fuera, y si es una opción, su valor con ella.
        index += 2 if argument.startswith("-") and "=" not in argument and following is not None \
            and not following.startswith("-") else 1
    return kept


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


CODEX_THREAD_SLACK_MS = 5000
CODEX_BACKGROUND_COMMANDS = frozenset(("app-server", "exec-server", "mcp-server", "exec", "mcp", "review", "login",
                                       "logout", "apply", "completion", "sandbox", "cloud", "proto", "debug"))


def codex_folder(pids, procesos, cwd_de_reserva):
    """La carpeta de un Codex: su ``-C``/``--cd`` (antes de ``--``) o la carpeta actual de sus procesos."""
    for pid in pids:
        argv = (procesos.get(pid) or {}).get("argv") or []
        options = []
        for value in argv[1:]:
            if value == "--":
                break
            options.append(value)
        for index, value in enumerate(options):
            if value in ("-C", "--cd") and index + 1 < len(options) and options[index + 1].startswith("/"):
                return options[index + 1]
            if value.startswith("--cd=") and value[5:].startswith("/"):
                return value[5:]
    for pid in pids:
        folder = cwd_de_reserva(pid)
        if isinstance(folder, str) and folder.startswith("/"):
            return folder
    return None


def codex_thread(root, branch, procesos, hilos_de, cwd_de_reserva, realpath):
    """El hilo de ``threads`` de un Codex sin rollout ni ``resume <uuid>``, o None (igual que el Mac)."""
    starts = [procesos[pid].get("start_ms") for pid in [root] + list(branch) if pid in procesos]
    starts = [value for value in starts if isinstance(value, int)]
    folder = codex_folder([root] + list(branch), procesos, cwd_de_reserva)
    if not starts or not folder:
        return None
    start, resolved = min(starts), realpath(folder)
    rows = hilos_de(sorted({folder, resolved}), int(procesos[root].get("uid", -1))) or []
    candidates = [row for row in rows if isinstance(row, dict)
                  and row.get("originator") == "codex-tui" and not row.get("archived")
                  and row.get("thread_source") != "subagent"
                  and isinstance(row.get("cwd"), str) and realpath(row["cwd"]) == resolved
                  and isinstance(row.get("created_at_ms"), int) and isinstance(row.get("updated_at_ms"), int)
                  and row["created_at_ms"] >= start - CODEX_THREAD_SLACK_MS]
    if not candidates:
        return None
    newest = max(candidates, key=lambda row: row["updated_at_ms"])
    if sum(1 for row in candidates if row["updated_at_ms"] == newest["updated_at_ms"]) > 1:
        return None
    own = {root} | set(branch)
    for pid, process in procesos.items():
        argv = process.get("argv") or []
        if pid in own or provider_of(argv) != "codex":
            continue
        words = []
        for value in argv[1:]:
            if value == "--":
                break
            words.append(value)
        if any(value in CODEX_BACKGROUND_COMMANDS for value in words):
            continue  # El app-server del Codex de escritorio, un exec…: no es otro TUI.
        other = codex_folder([pid], procesos, cwd_de_reserva)
        if not other or realpath(other) != resolved:
            continue
        other_start = process.get("start_ms")
        if not isinstance(other_start, int) or newest["created_at_ms"] >= other_start - CODEX_THREAD_SLACK_MS:
            return None  # Otro Codex vivo de esa carpeta pudo crear ese hilo: nadie lo recibe.
    return newest


def discover(pane_pid, procesos, ficha_de, abiertos_de, primera_linea_de, cwd_de_reserva, *,
             pane_path=None, realpath=None, sandbox_de=None, hilos_de=None):
    """Núcleo puro: la IA de un panel a partir de sus tablas.

    - ``procesos``: {pid: {"pid", "ppid", "uid", "argv"}} o una lista de esos dicts.
    - ``ficha_de(pid, uid)``: la ficha de Claude de ese pid (dict) o None.
    - ``abiertos_de(pid)``: rutas de los ficheros abiertos por ese pid.
    - ``primera_linea_de(ruta)``: primera línea (texto) de un rollout de Codex, o None.
    - ``cwd_de_reserva(pid)``: carpeta actual del proceso, o None.

    - ``sandbox_de(pid)``: True si el proceso tiene ``IS_SANDBOX=1`` en su entorno, o None.
    - ``hilos_de(carpetas, uid)``: filas de la tabla ``threads`` de Codex de esas carpetas (dicts con
      ``id``, ``cwd``, ``created_at_ms``, ``updated_at_ms``, ``originator``, ``archived``,
      ``thread_source``); los procesos llevan ``start_ms``. Sin ella no hay fuente ``threads``.

    Devuelve {"reason": None|"sin_ia"|"identidad_ambigua"|"sin_id", "agent": dict|None,
    "roots": [pid, ...]}. ``agent.launch`` lleva las opciones permitidas con que se lanzó.
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
        elif not found and hilos_de is not None:
            thread = codex_thread(root, branch, procesos, hilos_de, cwd_de_reserva, realpath)
            if thread:
                agent.update(session_id=canonical_id(thread["id"]) or thread["id"], source="threads", cwd=thread["cwd"])
    elif provider == "agy":
        value = option_value(argv, ("--conversation",), is_session_id)
        if value:
            agent.update(session_id=value, source="argv")
    elif provider == "grok":
        value = option_value(argv, ("-r", "--resume"), is_session_id)
        if value:
            agent.update(session_id=value, source="argv")
    options = launch_options(provider, argv)
    if options is not None:
        agent["launch"] = {"arguments": options,
                           "is_sandbox": bool(sandbox_de(root)) if sandbox_de is not None else None}
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


def _text(value, limit=200):
    """Texto de una línea, recortado, o None."""
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value[:limit] or None


def _flag(environment, name):
    """True si la variable está puesta con un valor que la activa (``1``, ``true``…)."""
    value = (environment or {}).get(name)
    if value is True:
        return True
    return isinstance(value, str) and value.strip().lower() not in ("", "0", "false", "no", "off")


def jwt_claims(token):
    """Lo que dice un JWT sin verificarlo (solo para leer el email y el plan), o {}."""
    if not isinstance(token, str) or token.count(".") != 2:
        return {}
    part = token.split(".")[1]
    part += "=" * (-len(part) % 4)
    try:
        value = json.loads(base64.urlsafe_b64decode(part.encode("ascii")).decode("utf-8"))
    except (ValueError, UnicodeError, binascii.Error):
        return {}
    return value if isinstance(value, dict) else {}


def token_fingerprint(token):
    """La huella de un token: los 16 primeros hex de su SHA-256, como ``openssl dgst -sha256 | cut -c1-16``."""
    return hashlib.sha256(token).hexdigest()[:16]


def token_account(text, huella):
    """El correo asociado a ``huella`` en ``~/.claude/cuentas-token`` (``<huella> <correo>`` por línea), o None."""
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 2 and not fields[0].startswith("#") and fields[0] == huella:
            email = _text(fields[1], 320)
            return email.lower() if email and "@" in email else None
    return None


def account_of(provider, uid, environment, read_file, user_of, read_at, usage_of=None, pid=None, read_text=None):
    """La cuenta de una IA en este momento (contracts/accounts-v1), sin caché.

    - ``environment``: rutas y banderas del entorno del proceso (``account_environment``) o None si
      no se pudo leer; entonces vale el HOME del usuario dueño del proceso.
    - ``read_file(ruta)``: ``("ok", dict)``, ``("absent", None)``, ``("denied", None)`` o
      ``("invalid", None)``. ``read_text(ruta)`` igual, con el texto del fichero.
    - ``user_of(uid)``: ``(nombre, home)`` del usuario, o ``(None, None)``.
    - ``usage_of(proveedor, carpeta, email, pid, uid, entorno)``: el último uso de ESA cuenta
      (``usage``), o None. ``carpeta`` es la de Claude (``CLAUDE_CONFIG_DIR`` o ``~/.claude``) o
      ``CODEX_HOME``; ``pid`` es la IA, para preguntar en vivo a su propio Codex.

    ``state``: ``ok`` (sabemos con qué entra), ``sin_sesion`` (no hay cuenta ni clave),
    ``no_legible`` (sus ficheros no se pueden leer con este usuario) o ``desconocida`` (UniConnect
    no sabe dónde guarda la cuenta ese proveedor).
    """
    name, home_of_user = user_of(uid)
    environment = environment or {}
    home = environment.get("HOME") or home_of_user
    account = {"state": "desconocida", "email": None, "method": None, "plan": None, "organization": None,
               "os_user": name, "config": None, "read_at": read_at, "usage": None}
    if provider == "claude":
        for flag, method in (("CLAUDE_CODE_USE_BEDROCK", "bedrock"), ("CLAUDE_CODE_USE_VERTEX", "vertex"),
                             ("CLAUDE_CODE_USE_FOUNDRY", "foundry")):
            if _flag(environment, flag):
                account.update(state="ok", method=method)
                return account
        config_dir = environment.get("CLAUDE_CONFIG_DIR")
        huella = environment.get(ACCOUNT_ENV_TOKEN)
        if isinstance(huella, str) and re.match(r"[0-9a-f]{16}\Z", huella):
            # Con un token de setup-token paga la cuenta del token, no la de .claude.json: su correo
            # sale del mapa «huella → correo» que mantiene Dani, y sin él no se adivina.
            mapping = os.path.join(home, ".claude", "cuentas-token") if home else None
            email = None
            if mapping and read_text is not None:
                status, text = read_text(mapping)
                if status == "denied":
                    account.update(state="no_legible", config=mapping)
                    return account
                email = token_account(text, huella) if status == "ok" else None
            account.update(state="ok", method="setup_token", email=email, config=mapping)
            if email and usage_of is not None:
                claude_dir = config_dir or (os.path.join(home, ".claude") if home else None)
                account["usage"] = usage_of("claude", claude_dir, email, pid, uid, environment) if claude_dir else None
            return account
        path = os.path.join(config_dir, ".claude.json") if config_dir else (
            os.path.join(home, ".claude.json") if home else None)
        if not path:
            return account
        account["config"] = path
        status, data = read_file(path)
        if status == "denied":
            account["state"] = "no_legible"
            return account
        oauth = data.get("oauthAccount") if status == "ok" and isinstance(data, dict) else None
        email = _text(oauth.get("emailAddress"), 320) if isinstance(oauth, dict) else None
        if email:
            plan = _text(oauth.get("planDisplayName"), 40)
            if not plan:
                credentials_dir = config_dir or (os.path.join(home, ".claude") if home else None)
                if credentials_dir:
                    found, credentials = read_file(os.path.join(credentials_dir, ".credentials.json"))
                    stored = credentials.get("claudeAiOauth") if found == "ok" and isinstance(credentials, dict) else None
                    kind = _text(stored.get("subscriptionType"), 40) if isinstance(stored, dict) else None
                    plan = kind.capitalize() if kind else None
            if not plan:
                plan = CLAUDE_PLANS.get(oauth.get("organizationType"))
            account.update(state="ok", method="oauth", email=email.lower(), plan=plan,
                           organization=_text(oauth.get("organizationName")))
            if usage_of is not None:
                claude_dir = config_dir or (os.path.join(home, ".claude") if home else None)
                account["usage"] = usage_of("claude", claude_dir, account["email"], pid, uid,
                                            environment) if claude_dir else None
        elif _flag(environment, "ANTHROPIC_API_KEY") or _flag(environment, "ANTHROPIC_AUTH_TOKEN"):
            account.update(state="ok", method="api_key")
        else:
            account["state"] = "sin_sesion"
        return account
    if provider == "codex":
        codex_home = environment.get("CODEX_HOME") or (os.path.join(home, ".codex") if home else None)
        if not codex_home:
            return account
        path = os.path.join(codex_home, "auth.json")
        account["config"] = path
        status, data = read_file(path)
        if status == "denied":
            account["state"] = "no_legible"
            return account
        data = data if status == "ok" and isinstance(data, dict) else {}
        tokens = data.get("tokens") if isinstance(data.get("tokens"), dict) else {}
        claims = jwt_claims(tokens.get("id_token"))
        email = _text(claims.get("email"), 320)
        auth = claims.get("https://api.openai.com/auth")
        auth = auth if isinstance(auth, dict) else {}
        if email:
            plan = _text(auth.get("chatgpt_plan_type"), 40)
            account.update(state="ok", method="chatgpt", email=email.lower(), plan=plan.capitalize() if plan else None)
            if usage_of is not None:
                account["usage"] = usage_of("codex", codex_home, account["email"], pid, uid, environment)
        elif data.get("OPENAI_API_KEY") or _flag(environment, "OPENAI_API_KEY"):
            account.update(state="ok", method="api_key")
        else:
            account["state"] = "sin_sesion"
        return account
    return account


CLAUDE_LIMIT_WINDOWS = {"five_hour": 300, "seven_day": 10080}


def _iso_epoch(value):
    """Un instante en segundos (o ya en ISO) como ISO 8601 UTC, o None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and value > 0:
        try:
            return iso_now(float(value))
        except (OverflowError, OSError, ValueError):
            return None
    if isinstance(value, str) and re.match(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", value):
        return value[:19] + "Z"
    return None


def _percent(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return round(max(0.0, min(float(value), 1000.0)), 1)


def claude_usage(document, email):
    """``usage`` a partir de ``uniconnect-uso.json`` (lo que la barra de estado oyó a Claude).

    Solo vale si es de ESA cuenta: tras un ``/login`` con otra, el fichero viejo no se atribuye.
    """
    if not isinstance(document, dict) or document.get("version") != 1 or not email:
        return None
    if not isinstance(document.get("email"), str) or document["email"].strip().lower() != email:
        return None
    limits = []
    rate_limits = document.get("rate_limits")
    for name, value in (rate_limits.items() if isinstance(rate_limits, dict) else ()):
        if not isinstance(value, dict) or not re.match(r"[a-z0-9_]{1,40}\Z", str(name)):
            continue
        used = _percent(value.get("used_percentage"))
        if used is None:
            continue
        window = CLAUDE_LIMIT_WINDOWS.get(name, 10080 if name.startswith("seven_day") else None)
        limits.append({"id": name, "used_percent": used, "resets_at": _iso_epoch(value.get("resets_at")),
                       "window_minutes": window})
    order = {"five_hour": 0, "seven_day": 1}
    limits.sort(key=lambda item: (order.get(item["id"], 2), item["id"]))
    observed = _iso_epoch(document.get("observed_at"))
    if not limits or not observed:
        return None
    return {"source": "statusline", "observed_at": observed, "limits": limits}


def codex_live_usage(result, observed_at):
    """``usage`` a partir de ``account/rateLimits/read`` del app-server oficial de Codex (en vivo).

    Añade ``reset_credits`` (``{available, next_expires_at}``) cuando Codex ofrece reseteos gratis.
    """
    if not isinstance(result, dict):
        return None
    rate_limits = result.get("rateLimits")
    if not isinstance(rate_limits, dict):
        return None
    limits = []
    for name in ("primary", "secondary"):
        value = rate_limits.get(name)
        if not isinstance(value, dict):
            continue
        used = _percent(value.get("usedPercent"))
        if used is None:
            continue
        window = value.get("windowDurationMins")
        window = int(window) if isinstance(window, (int, float)) and not isinstance(window, bool) and window > 0 else None
        limits.append({"id": name, "used_percent": used, "resets_at": _iso_epoch(value.get("resetsAt")),
                       "window_minutes": window})
    if not limits:
        return None
    usage = {"source": "app_server", "observed_at": observed_at, "limits": limits}
    credits = result.get("rateLimitResetCredits")
    if isinstance(credits, dict):
        available = [item for item in (credits.get("credits") or []) if isinstance(item, dict)
                     and item.get("status") == "available"]
        count = credits.get("availableCount")
        count = count if isinstance(count, int) and not isinstance(count, bool) else len(available)
        if count > 0:
            expiries = [item.get("expiresAt") for item in available
                        if isinstance(item.get("expiresAt"), (int, float)) and not isinstance(item.get("expiresAt"), bool)]
            usage["reset_credits"] = {"available": count,
                                      "next_expires_at": _iso_epoch(min(expiries)) if expiries else None}
    return usage


def codex_usage(event):
    """``usage`` a partir del último evento ``token_count`` con ``rate_limits`` de un rollout."""
    if not isinstance(event, dict):
        return None
    payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
    rate_limits = payload.get("rate_limits")
    observed = _iso_epoch(event.get("timestamp"))
    if not isinstance(rate_limits, dict) or not observed:
        return None
    limits = []
    for name in ("primary", "secondary"):
        value = rate_limits.get(name)
        if not isinstance(value, dict):
            continue
        used = _percent(value.get("used_percent"))
        if used is None:
            continue
        window = value.get("window_minutes")
        window = int(window) if isinstance(window, (int, float)) and not isinstance(window, bool) and window > 0 else None
        resets = _iso_epoch(value.get("resets_at"))
        if resets is None and isinstance(value.get("resets_in_seconds"), (int, float)):
            try:
                base = datetime.datetime.strptime(observed, "%Y-%m-%dT%H:%M:%SZ")
                moment = base + datetime.timedelta(seconds=float(value["resets_in_seconds"]))
                resets = moment.strftime("%Y-%m-%dT%H:%M:%SZ")
            except (ValueError, OverflowError):
                resets = None
        limits.append({"id": name, "used_percent": used, "resets_at": resets, "window_minutes": window})
    if not limits:
        return None
    return {"source": "rollout", "observed_at": observed, "limits": limits}


class HostReader:
    """Lectores reales del host (solo lectura). Linux usa /proc; macOS, ps y lsof."""

    def __init__(self):
        self.proc = os.path.isdir("/proc/self/fd")
        self.environment = dict(os.environ)
        self.environment["PATH"] = SEARCH_PATH + ":" + self.environment.get("PATH", "")
        self.truncated = False
        config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
        self.own_sessions = os.path.join(config, "sessions")
        self._account_files = {}  # una sonda = un lector: nunca sobrevive a la llamada

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
                table[pid] = {"pid": pid, "ppid": int(fields[1]), "uid": uid, "argv": argv,
                              "start_ms": self._start_ms(fields)}
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

    def _start_ms(self, fields):
        """Arranque del proceso en ms desde 1970: campo 22 de /proc/<pid>/stat más el btime del arranque."""
        try:
            if not hasattr(self, "_boot"):
                with open("/proc/stat") as handle:
                    self._boot = next(int(line.split()[1]) for line in handle if line.startswith("btime "))
                self._ticks = os.sysconf("SC_CLK_TCK")
            return int((self._boot + int(fields[19]) / self._ticks) * 1000)
        except (OSError, ValueError, IndexError, StopIteration):
            return None

    def threads(self, folders, uid):
        """Filas de ``threads`` de Codex de esas carpetas, del ``state_<n>.sqlite`` más alto, en solo lectura."""
        try:
            import sqlite3
        except ImportError:
            return []
        homes = []
        if os.environ.get("CODEX_HOME") and os.geteuid() == uid:
            homes.append(os.environ["CODEX_HOME"])
        try:
            homes.append(os.path.join(pwd.getpwuid(uid).pw_dir, ".codex"))
        except (KeyError, OverflowError, TypeError):
            pass
        for home in dict.fromkeys(homes):
            try:
                names = os.listdir(home)
            except OSError:
                continue
            versions = sorted((int(name[6:-7]), name) for name in names
                              if name.startswith("state_") and name.endswith(".sqlite") and name[6:-7].isdigit())
            if not versions:
                continue
            path = os.path.join(home, versions[-1][1])
            try:
                connection = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=0.5)
                try:
                    columns = {row[1] for row in connection.execute("PRAGMA table_info(threads)")}
                    if not {"id", "cwd", "created_at", "updated_at", "archived"} <= columns:
                        return []
                    created = "coalesce(created_at_ms, created_at * 1000)" if "created_at_ms" in columns else "created_at * 1000"
                    updated = "coalesce(updated_at_ms, updated_at * 1000)" if "updated_at_ms" in columns else "updated_at * 1000"
                    originator = "originator" if "originator" in columns else "NULL"
                    source = "thread_source" if "thread_source" in columns else "NULL"
                    marks = ",".join("?" for _ in folders)
                    rows = connection.execute(
                        "SELECT id, cwd, %s, %s, %s, archived, %s FROM threads WHERE cwd IN (%s) ORDER BY %s DESC LIMIT 256"
                        % (created, updated, originator, source, marks, updated), list(folders)).fetchall()
                finally:
                    connection.close()
            except sqlite3.Error:
                return []
            return [{"id": row[0], "cwd": row[1], "created_at_ms": row[2], "updated_at_ms": row[3],
                     "originator": row[4], "archived": bool(row[5]), "thread_source": row[6]} for row in rows]
        return []

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

    def sandbox(self, pid):
        """True/False según ``IS_SANDBOX=1`` en el entorno del proceso; None si no se puede leer.

        Solo se mira esa variable: el resto del entorno ni se guarda ni sale de aquí.
        """
        if not self.proc:
            return None
        try:
            with open("/proc/%d/environ" % pid, "rb") as handle:
                raw = handle.read(1048576)
        except OSError:
            return None
        return b"IS_SANDBOX=1" in raw.split(b"\0")

    def account_environment(self, pid):
        """Solo ACCOUNT_ENV_PATHS (valor) y ACCOUNT_ENV_FLAGS (``True`` si están puestas), o None.

        Linux: /proc/<pid>/environ. macOS: sysctl KERN_PROCARGS2 (solo procesos del mismo usuario).
        """
        raw = None
        if self.proc:
            try:
                with open("/proc/%d/environ" % pid, "rb") as handle:
                    raw = handle.read(1048576).split(b"\0")
            except OSError:
                return None
        else:
            raw = _darwin_environment(pid)
            if raw is None:
                return None
        values = {}
        for item in raw:
            name, sep, value = item.partition(b"=")
            if not sep:
                continue
            name = name.decode("utf-8", "replace")
            if name in ACCOUNT_ENV_PATHS:
                text = value.decode("utf-8", "replace")
                if text.startswith("/"):
                    values[name] = text
            elif name in ACCOUNT_ENV_FLAGS and value.strip():
                values[name] = value.decode("utf-8", "replace") if name.startswith("CLAUDE_CODE_USE_") else True
            elif name == ACCOUNT_ENV_TOKEN and value.strip():
                values[name] = token_fingerprint(value)
        return values

    def read_account_text(self, path):
        """Lee un fichero de texto de cuentas (``cuentas-token``) en este momento, sin seguir más de 64 KB."""
        try:
            with open(path, "rb") as handle:
                raw = handle.read(MAX_TOKEN_MAP + 1)
            if len(raw) > MAX_TOKEN_MAP:
                return ("invalid", None)
            return ("ok", raw.decode("utf-8"))
        except (FileNotFoundError, NotADirectoryError):
            return ("absent", None)
        except PermissionError:
            return ("denied", None)
        except (OSError, UnicodeError):
            return ("invalid", None)

    def read_account_file(self, path):
        """Lee un JSON de cuenta en este momento; se recuerda solo durante esta misma sonda."""
        if path in self._account_files:
            return self._account_files[path]
        try:
            with open(path, "rb") as handle:
                raw = handle.read(MAX_ACCOUNT_FILE + 1)
            if len(raw) > MAX_ACCOUNT_FILE:
                result = ("invalid", None)
            else:
                value = json.loads(raw.decode("utf-8"))
                result = ("ok", value) if isinstance(value, dict) else ("invalid", None)
        except (FileNotFoundError, NotADirectoryError):
            result = ("absent", None)
        except PermissionError:
            result = ("denied", None)
        except (OSError, ValueError, UnicodeError):
            result = ("invalid", None)
        self._account_files[path] = result
        return result

    def usage_of(self, provider, folder, email, pid=None, uid=None, environment=None):
        """El uso de esa cuenta en ese host, o None (contracts/accounts-v1 §2.4).

        Codex: primero en vivo a su propio app-server (mismo binario, mismo usuario y su
        ``CODEX_HOME``); si no se puede, el último ``token_count`` de sus rollouts.
        """
        if provider == "claude":
            huella = (environment or {}).get(ACCOUNT_ENV_TOKEN)
            if isinstance(huella, str) and re.match(r"[0-9a-f]{16}\Z", huella):
                # La barra deja el uso de cada token en su propio fichero, por huella.
                status, document = self.read_account_file(os.path.join(folder, "uniconnect-uso-%s.json" % huella))
                usage = claude_usage(document, email) if status == "ok" else None
                if usage is not None:
                    return usage
            status, document = self.read_account_file(os.path.join(folder, "uniconnect-uso.json"))
            return claude_usage(document, email) if status == "ok" else None
        if provider != "codex":
            return None
        if not hasattr(self, "_codex_live"):
            self._codex_live = {}
        if folder not in self._codex_live:
            self._codex_live[folder] = self._codex_app_server(pid, uid, folder, environment or {})
        if self._codex_live[folder] is not None:
            return self._codex_live[folder]
        event, observed = self._codex_latest_rate_limits(os.path.join(folder, "sessions"))
        if event is None:
            return None
        try:
            # Si auth.json cambió después (otro login), ese uso puede ser de la cuenta anterior.
            if os.stat(os.path.join(folder, "auth.json")).st_mtime > observed + 60:
                return None
        except OSError:
            return None
        return codex_usage(event)

    def _codex_command(self, pid):
        """La orden de ESE Codex para lanzar ``app-server``, o None."""
        argv = []
        executable = None
        if self.proc:
            try:
                executable = os.readlink("/proc/%d/exe" % pid)
                with open("/proc/%d/cmdline" % pid, "rb") as handle:
                    argv = [part.decode("utf-8", "replace") for part in handle.read(65536).split(b"\0") if part]
            except OSError:
                return None
        else:
            result = self.run(["ps", "-ww", "-o", "args=", "-p", str(pid)])
            argv = (result.stdout if result and result.returncode == 0 else "").split()
            executable = argv[0] if argv else None
        if not executable:
            return None
        base = basename(executable)
        if NODE.match(base) and len(argv) > 1:
            return [executable, argv[1], "app-server"]
        if not base.startswith("codex"):
            return None
        if not executable.startswith("/"):
            for folder in SEARCH_PATH.split(":"):
                candidate = os.path.join(folder, executable)
                if os.access(candidate, os.X_OK):
                    executable = candidate
                    break
            else:
                return None
        return [executable, "app-server"]

    def _codex_app_server(self, pid, uid, folder, environment, timeout=6.0):
        """``account/rateLimits/read`` del app-server oficial de ESE Codex, o None."""
        answers = self._codex_rpc(pid, uid, folder, environment, [("account/rateLimits/read", None)], timeout)
        result = answers.get(0) if answers else None
        return codex_live_usage(result, iso_now()) if result is not None else None

    def _codex_rpc(self, pid, uid, folder, environment, calls, timeout=6.0):
        """Llama en orden a ``calls`` (``[(método, params)]``) en el app-server de ESE Codex.

        Devuelve ``{índice: result}`` de las que contestaron, o None si no se pudo arrancar.
        Solo con el mismo usuario que la IA (nunca escribe en la carpeta de otro). Sin tokens: es
        el propio Codex quien pregunta, igual que hace su interfaz cada pocos segundos.
        """
        if pid is None or uid is None or uid != os.geteuid():
            return None
        command = self._codex_command(pid)
        if not command:
            return None
        env = dict(os.environ)
        env["PATH"] = SEARCH_PATH + ":" + env.get("PATH", "")
        if environment.get("HOME"):
            env["HOME"] = environment["HOME"]
        env["CODEX_HOME"] = folder
        try:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, env=env, start_new_session=True)
        except OSError:
            return None
        deadline = time.time() + timeout
        buffer = b""
        answers = {}
        pending = 0

        def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
            process.stdin.flush()

        def send_call(index):
            method, params = calls[index]
            message = {"jsonrpc": "2.0", "id": 100 + index, "method": method}
            if params is not None:
                message["params"] = params
            send(message)

        try:
            send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": {"clientInfo": {"name": "uniconnect-accounts", "title": "UniConnect", "version": "1"}}})
            while len(answers) < len(calls) and time.time() < deadline:
                ready, _, _ = select.select([process.stdout], [], [], 0.25)
                if not ready:
                    continue
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    try:
                        message = json.loads(line.decode("utf-8"))
                    except (ValueError, UnicodeError):
                        continue
                    if not isinstance(message, dict):
                        continue
                    if message.get("id") == 1:
                        send({"jsonrpc": "2.0", "method": "initialized"})
                        send_call(0)
                    elif isinstance(message.get("id"), int) and 100 <= message["id"] < 100 + len(calls):
                        index = message["id"] - 100
                        answers[index] = message.get("result") if "result" in message else {"error": message.get("error")}
                        # En orden: la siguiente solo cuando contestó la anterior.
                        if index + 1 < len(calls):
                            send_call(index + 1)
        except (OSError, ValueError):
            pass
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except (OSError, AttributeError):
                process.kill()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        return answers

    def codex_reset(self, pid, uid, folder, environment, idempotency_key):
        """Gasta un reseteo gratis de ESA cuenta de Codex (accounts-v1 §5) y relee su uso.

        Devuelve ``{"outcome", "usage"}`` o ``{"error"}``. Lo único que escribe esta sonda, y solo
        con ``--codex-reset``.
        """
        answers = self._codex_rpc(pid, uid, folder, environment, [
            ("account/rateLimitResetCredit/consume", {"idempotencyKey": idempotency_key}),
            ("account/rateLimits/read", None),
        ], timeout=8.0)
        if answers is None:
            return {"error": "codex_no_disponible"}
        consumed = answers.get(0)
        if not isinstance(consumed, dict) or consumed.get("outcome") not in ("reset", "nothingToReset", "noCredit",
                                                                          "alreadyRedeemed"):
            return {"error": "codex_no_contesto"}
        return {"outcome": consumed["outcome"], "usage": codex_live_usage(answers.get(1), iso_now())}

    @staticmethod
    def _codex_latest_rate_limits(sessions):
        """(evento, instante) del último ``token_count`` con ``rate_limits`` de los rollouts.

        Un ``codex resume`` sigue escribiendo en el rollout del día en que nació la sesión, así que
        se recorre todo el árbol y se miran los 6 ficheros modificados más recientemente.
        """
        candidates = []
        for root, _, files in os.walk(sessions):
            for name in files:
                if name.endswith(".jsonl"):
                    path = os.path.join(root, name)
                    try:
                        candidates.append((os.stat(path).st_mtime, path))
                    except OSError:
                        continue
        for _, path in heapq.nlargest(6, candidates):
            try:
                with open(path, "rb") as handle:
                    handle.seek(0, os.SEEK_END)
                    size = handle.tell()
                    handle.seek(max(0, size - 1048576))
                    lines = handle.read().split(b"\n")
            except OSError:
                continue
            for raw in reversed(lines):
                if b'"rate_limits"' not in raw or b'"token_count"' not in raw:
                    continue
                try:
                    event = json.loads(raw.decode("utf-8"))
                except (ValueError, UnicodeError):
                    continue
                payload = event.get("payload") if isinstance(event, dict) else None
                if not isinstance(payload, dict) or not isinstance(payload.get("rate_limits"), dict):
                    continue
                try:
                    moment = datetime.datetime.strptime(str(event.get("timestamp"))[:19], "%Y-%m-%dT%H:%M:%S")
                except ValueError:
                    continue
                return event, (moment - datetime.datetime(1970, 1, 1)).total_seconds()
        return None, 0

    @staticmethod
    def user_of(uid):
        try:
            entry = pwd.getpwuid(uid)
            return entry.pw_name, entry.pw_dir
        except (KeyError, OverflowError, TypeError):
            return None, None

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


def _darwin_environment(pid):
    """Entorno (lista de ``b"CLAVE=valor"``) de un proceso en macOS, o None si no se puede leer."""
    try:
        import ctypes
        import ctypes.util
        libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        mib = (ctypes.c_int * 3)(1, 49, int(pid))  # CTL_KERN, KERN_PROCARGS2
        size = ctypes.c_size_t(0)
        if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or not size.value:
            return None
        buffer = ctypes.create_string_buffer(size.value)
        if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
            return None
    except (OSError, AttributeError, ValueError):
        return None
    raw = buffer.raw[:size.value]
    if len(raw) < 4:
        return None
    argc = int.from_bytes(raw[:4], sys.byteorder)
    position = raw.find(b"\0", 4)  # tras la ruta del ejecutable vienen NUL de relleno
    if position < 0:
        return None
    while position < len(raw) and raw[position] == 0:
        position += 1
    parts = raw[position:].split(b"\0")
    environment = []
    for item in parts[argc:]:
        if not item:
            break
        environment.append(item)
    return environment


def iso_now(now=None):
    moment = datetime.datetime.utcfromtimestamp(now if now is not None else time.time())
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def probe(socket_name="default", sessions=(), reader=None, now=None, accounts=False, codex_reset=None):
    """Lee el host y devuelve el JSON v1 (dict) de contracts/agent-tree-v1/sonda-salida.json.

    Con ``accounts`` cada ``agent`` lleva también ``account`` (contracts/accounts-v1).
    Con ``codex_reset`` (una clave de idempotencia) se gasta un reseteo gratis del Codex de la
    única sesión pedida y la salida lleva ``codex_reset`` (accounts-v1 §5).
    """
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
                              reader.cwd, pane_path=pane["current_path"], realpath=reader.realpath,
                              sandbox_de=getattr(reader, "sandbox", None), hilos_de=getattr(reader, "threads", None))
            results.append((pane, result))
        chosen, result = combine(results)
        if accounts and result["agent"]:
            agent = dict(result["agent"])
            process = table.get(agent["pid"], {})
            agent["account"] = account_of(
                agent["provider"], int(process.get("uid", -1)), reader.account_environment(agent["pid"]),
                reader.read_account_file, reader.user_of, output["checked_at"], getattr(reader, "usage_of", None),
                agent["pid"], read_text=getattr(reader, "read_account_text", None))
            result = dict(result, agent=agent)
        output["sessions"].append({
            "name": name, "session_id": members[0]["session_id"],
            "pane_id": chosen["pane_id"] if chosen else None,
            "pane_pid": chosen["pane_pid"] if chosen else None,
            "live": True, "reason": result["reason"], "agent": result["agent"],
            "panes": [{key: pane[key] for key in ("pane_id", "window_index", "pane_pid", "dead",
                                                   "current_path", "current_command")} for pane in members]})
    output["truncated"] = bool(reader.truncated)
    if codex_reset is not None:
        output["codex_reset"] = _codex_reset_for(output, table, reader, codex_reset)
    return output


def _codex_reset_for(output, table, reader, idempotency_key):
    """El reseteo de Codex de la única sesión pedida, o ``{"error"}`` si no es un Codex con cuenta."""
    sessions = output["sessions"]
    if len(sessions) != 1:
        return {"error": "sesion_no_encontrada"}
    agent = sessions[0].get("agent") or {}
    if agent.get("provider") != "codex":
        return {"error": "no_es_codex"}
    process = table.get(agent["pid"], {})
    uid = int(process.get("uid", -1))
    environment = reader.account_environment(agent["pid"]) or {}
    _, home = reader.user_of(uid)
    folder = environment.get("CODEX_HOME") or os.path.join(environment.get("HOME") or home or "/", ".codex")
    return reader.codex_reset(agent["pid"], uid, folder, environment, idempotency_key)


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
    """CLI: ``[--socket NOMBRE|default] [--session NOMBRE]... [--accounts]``.

    Devuelve (socket, sesiones, cuentas) o None.
    """
    socket_name, sessions, index, accounts, codex_reset = "default", [], 0, False, None
    while index < len(arguments):
        option = arguments[index]
        if option == "--accounts":
            accounts = True
            index += 1
            continue
        if option == "--codex-reset" and index + 1 < len(arguments):
            if not re.match(r"[A-Za-z0-9-]{8,80}\Z", arguments[index + 1]):
                return None
            codex_reset = arguments[index + 1]
            index += 2
            continue
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
    if codex_reset is not None and len(sessions) != 1:
        return None
    return socket_name, sessions, accounts, codex_reset


def main(arguments=None, reader=None, stdout=None, now=None):
    stdout = stdout or sys.stdout
    parsed = parse_arguments(sys.argv[1:] if arguments is None else list(arguments))
    if parsed is None:
        sys.stderr.write("uso: agent_probe.py [--socket NOMBRE|default] [--session NOMBRE]... [--accounts] [--codex-reset CLAVE]\n")
        return 2
    socket_name, sessions, accounts, codex_reset = parsed
    try:
        output = probe(socket_name, sessions, reader=reader, now=now, accounts=accounts, codex_reset=codex_reset)
    except Exception as error:  # La sonda nunca falla con traza: el error viaja en el JSON.
        output = {"version": VERSION, "checked_at": iso_now(now), "socket": socket_name, "host": None,
                  "server": False, "error": "sonda_fallo: " + type(error).__name__, "truncated": False,
                  "sessions": []}
    stdout.write(encode(output) + "\n")
    stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
