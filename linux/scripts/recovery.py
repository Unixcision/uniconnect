#!/usr/bin/env python3
"""Supervisor de recuperación de UniConnect.

Mantiene vivas las ventanas tmux del manifiesto con la IA que tenían, y las devuelve todas tras un
reinicio de la máquina o una caída del servidor tmux. Toda IA vuelve **sin preguntas**
(`docs/ARBOL-IA-v1.md`, sección 6): una sesión recuperada que se para a pedir permiso es una sesión
muerta.

El manifiesto no es una lista fija: `snapshot` aprende las sesiones que existen ahora (nombre,
carpeta, IA y conversación leídas del proceso vivo), así que una ventana creada después de instalar
también queda protegida. Una ventana cerrada a propósito se olvida en vez de resucitarla: que falte
una sesión con la misma máquina y el mismo servidor tmux que la vieron viva es un cierre deliberado;
que falten todas a la vez, o un arranque nuevo, es una caída o un reinicio.

La detección es una **copia** del criterio común (`contracts/agent-tree-v1/deteccion-casos.json`):
este fichero se despliega solo en el VPS y no puede importar la sonda compartida
(`linux/uniconnect/agent_probe.py`). Las dos se prueban con el mismo fixture.

Nunca envía teclas, nunca usa sudo y nunca cambia opciones de una sesión que ya existía ni de un
servidor tmux que ya estaba en marcha: las opciones de servidor solo acompañan al `new-session` que
lo arranca (D4, `contracts/agent-tree-v1/LEEME.md`).

Solo recupera las entradas de **su** manifiesto (D6). Una sesión viva cuyo `@uniconnect_session_id`
es de otro dueño se salta; una que vive sin dueño (la creó otro, por ejemplo UniConnect desde un
escritorio) se vigila como adoptada y nunca se reconfigura.

Acciones: validate, snapshot, ensure, supervise, launch <tmux>, status, forget <tmux>.
"""
import argparse, fcntl, json, os, re, shlex, shutil, sqlite3, subprocess, sys, time
from collections import deque
from pathlib import Path

# ---------------------------------------------------------------- política sin preguntas
#
# Copia de `noPrompt` en Packages/CMUXAgentLaunch/Sources/CMUXAgentLaunch/Resources/agent-resume-v1.json
# (este fichero se despliega solo y no puede leer el catálogo). test_recovery_v2 la compara con él.
# La regla de aplicación está en `apply_no_prompt` y es la de contracts/agent-tree-v1/LEEME.md.
NO_PROMPT = {
    "claude": {"suffix": ["--dangerously-skip-permissions"], "rootEnvironment": {"IS_SANDBOX": "1"}},
    "codex": {"prefix": ["--yolo"], "legacy": ["--dangerously-bypass-approvals-and-sandbox"],
              # Codex rechaza --yolo junto a cualquiera de estas (D2): se quitan con su valor.
              "supersedes": [{"flag": "-a", "takesValue": True}, {"flag": "--ask-for-approval", "takesValue": True},
                             {"flag": "-s", "takesValue": True}, {"flag": "--sandbox", "takesValue": True},
                             {"flag": "--full-auto", "takesValue": False}]},
    "agy": {"prefix": ["--dangerously-skip-permissions"]},
}
# Plantillas `resume` del catálogo. `{arguments}` son las opciones conservadas (en Codex, las de la
# ventana: -C, -m, -c); sin ellas es la forma canónica que enseña Detalles.
RESUME = {
    "claude": ["claude", "--resume", "{sessionId}", "{arguments}"],
    "codex": ["codex", "resume", "{sessionId}", "{arguments}"],
    "agy": ["agy", "--conversation", "{sessionId}", "{arguments}"],
    "grok": ["grok", "-r", "{sessionId}", "{arguments}"],
}
AGENTS = tuple(RESUME)

# Los UUID de argv se aceptan en mayúsculas y se comparan y guardan en minúsculas.
UUID_CI = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
UUID_ANY = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
SESSION_ID = re.compile(r"^[A-Za-z0-9_-]{1,160}$")
SAFE_TOKEN = re.compile(r"^[A-Za-z0-9@%_+=:,./-]+$")
ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
NODE = re.compile(r"^(node|nodejs|bun)(\d+(\.\d+)*)?$")
MAX_DEPTH, MAX_NODES = 8, 256

_warned = set()


def warn_once(key, message):
    """Una avería que no cambia no se repite cada 15 segundos en el registro."""
    if key in _warned:
        return
    _warned.add(key)
    print(message, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- manifiesto

def load_manifest(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    data.setdefault("tmuxSocket", "default")
    data.setdefault("windows", [])
    return data


def save_manifest(path, data):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def update_manifest(path, change, fallback=None):
    """Relee el manifiesto del disco, aplica `change` y guarda si cambió algo.

    Así un `forget` o una edición a mano hechos mientras el supervisor daba su vuelta no se pisan:
    lo aprendido se **fusiona** sobre lo que hay ahora, no sobre lo que había al empezar.
    """
    with open(str(path) + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = load_manifest(path) if path.exists() else (fallback if fallback is not None else {"windows": []})
        data.setdefault("tmuxSocket", "default")
        data.setdefault("windows", [])
        if change(data):
            save_manifest(path, data)
        return data


def entry_socket(data, entry):
    return entry.get("tmuxSocket") or data.get("tmuxSocket") or "default"


def watched_sockets(data):
    """Los servidores tmux vigilados: `tmuxSockets` (o `tmuxSocket`) y los de cada entrada."""
    sockets = list(data.get("tmuxSockets") or [data.get("tmuxSocket") or "default"])
    for entry in data.get("windows", []):
        socket = entry_socket(data, entry)
        if socket not in sockets:
            sockets.append(socket)
    return sockets


def entry_key(data, entry):
    return entry_socket(data, entry), entry["tmux"]


def boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def project_folder(cwd):
    # Como lo hace Claude Code: TODO lo que no sea letra o numero pasa a ser un guion. Cambiar
    # solo `/` y `_` perdia las conversaciones de carpetas con puntos (dominios, versiones).
    return Path.home() / ".claude/projects" / re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(cwd))


# ---------------------------------------------------------------- órdenes

def canonical_argv(provider, session_id, arguments=()):
    """argv de reanudar: la plantilla del catálogo con `arguments` y la política sin preguntas."""
    if provider not in RESUME:
        raise ValueError("IA desconocida: " + str(provider))
    if not SESSION_ID.match(session_id or ""):
        raise ValueError("Identificador de conversación no válido")
    argv = []
    for token in RESUME[provider]:
        if token == "{sessionId}":
            argv.append(session_id)
        elif token == "{arguments}":
            argv.extend(str(argument) for argument in arguments)
        else:
            argv.append(token)
    return apply_no_prompt(provider, argv)


def apply_no_prompt(provider, argv):
    """La regla única de `noPrompt` (contracts/agent-tree-v1/LEEME.md), igual que en el Mac y Linux.

    De argv[1:] se quitan prefix, suffix y legacy, y cada bandera de `supersedes` con su valor
    (`-a never`, `-a=never`, `--sandbox=…`, también las cortas con `=`). Después prefix va justo
    detrás del ejecutable y suffix al final, una sola vez. Aplicarla dos veces da lo mismo que una.
    """
    policy = NO_PROMPT.get(provider, {})
    plain = set(policy.get("prefix", [])) | set(policy.get("suffix", [])) | set(policy.get("legacy", []))
    supersedes = {item["flag"]: bool(item["takesValue"]) for item in policy.get("supersedes", [])}
    kept, rest, index = [], list(argv[1:]), 0
    while index < len(rest):
        token = rest[index]
        index += 1
        if token in plain:
            continue
        if token in supersedes:
            if supersedes[token] and index < len(rest):
                index += 1                # su valor va con ella
            continue
        if "=" in token and supersedes.get(token.split("=", 1)[0]):
            continue
        kept.append(token)
    return [argv[0], *policy.get("prefix", []), *kept, *policy.get("suffix", [])]


def resume_environment(provider, as_root):
    return dict(NO_PROMPT.get(provider, {}).get("rootEnvironment", {})) if as_root else {}


def quote_token(token):
    return token if SAFE_TOKEN.match(token) else "'" + token.replace("'", "'\\''") + "'"


def shell_command(cwd, argv, environment):
    """`cd -- '<cwd>' && [K=V ]argv`, como en contracts/agent-tree-v1/reanudar-comandos.json."""
    for name, value in environment.items():
        if not ENV_NAME.match(name) or not SAFE_TOKEN.match(value):
            raise ValueError("Variable de entorno no válida para la orden: " + name)
    prefix = "".join(name + "=" + value + " " for name, value in environment.items())
    return "cd -- '" + cwd.replace("'", "'\\''") + "' && " + prefix + " ".join(quote_token(a) for a in argv)


def canonical_resume(provider, session_id, cwd, as_root, arguments=()):
    """argv, entorno y orden de shell, como en contracts/agent-tree-v1/reanudar-comandos.json.

    Sin `arguments` es la forma canónica que Detalles enseña como «Orden para reanudarla».
    """
    argv = canonical_argv(provider, session_id, arguments)
    environment = resume_environment(provider, as_root)
    return {"argv": argv, "environment": environment, "command": shell_command(cwd, argv, environment),
            "no_prompt_verified": provider in NO_PROMPT}


def claude_executable(entry):
    for candidate in (entry.get("executable"), str(Path.home() / ".local/bin/claude"), shutil.which("claude")):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    raise ValueError("Claude no está instalado")


def environment_for(entry):
    """Claude rechaza su modo sin preguntas como root salvo que el entorno diga que está aislado;
    las sesiones que esto recupera se abrieron así, y así tienen que volver."""
    env = dict(os.environ)
    env.update(resume_environment(entry["agent"], os.geteuid() == 0))
    return env


def trust_folder_for_claude(cwd):
    """Claude stops at "Do you trust this folder?" the first time it opens a directory. Nobody
    is there to answer during a recovery, so the answer the user gave is written ahead of time."""
    config = Path.home() / ".claude.json"
    try:
        data = json.loads(config.read_text(encoding="utf-8")) if config.is_file() else {}
    except (OSError, ValueError):
        return
    projects = data.setdefault("projects", {})
    project = projects.setdefault(os.path.realpath(cwd), {})
    if project.get("hasTrustDialogAccepted"):
        return
    project["hasTrustDialogAccepted"] = True
    tmp = config.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(config)


def command_for(entry):
    """argv con el que se lanza de verdad: el ejecutable resuelto y, en Codex, las opciones de la
    ventana (-C, -m, -c) como `{arguments}` de la plantilla, con la misma política que el resto."""
    agent = entry["agent"]
    if agent == "command":
        return ["bash", "-lc", entry["command"]]
    if agent not in RESUME:
        raise ValueError("IA desconocida en el manifiesto: " + str(agent))
    arguments = []
    if agent == "codex":
        arguments += ["-C", entry["cwd"]]
        if entry.get("model"):
            arguments += ["-m", entry["model"]]
        if entry.get("reasoningEffort"):
            arguments += ["-c", "model_reasoning_effort=" + json.dumps(entry["reasoningEffort"])]
    argv = canonical_argv(agent, entry["sessionId"], arguments)
    if agent == "claude":
        executable = claude_executable(entry)
    else:
        executable = shutil.which(RESUME[agent][0])
        if executable is None:
            raise ValueError("El cliente de " + agent + " no está instalado o no está en el PATH")
    argv[0] = executable
    return argv


def shell_command_for(entry, as_root=None):
    """La orden canónica para enseñar (`status`), o None si la entrada no es de una IA conocida."""
    if entry.get("agent") not in RESUME or not SESSION_ID.match(entry.get("sessionId") or ""):
        return None
    if as_root is None:
        as_root = entry.get("asRoot", os.geteuid() == 0)
    return canonical_resume(entry["agent"], entry["sessionId"], entry.get("cwd") or ".", bool(as_root))["command"]


def verify_session(entry):
    if not Path(entry["cwd"]).is_dir() or (entry.get("repo") and not Path(entry["repo"]).is_dir()):
        raise ValueError("Falta la carpeta de trabajo")
    agent = entry["agent"]
    if agent in ("command", "grok"):
        # Grok no deja un fichero de conversación que se pueda comprobar desde fuera.
        return
    if agent == "claude":
        if not (project_folder(entry["cwd"]) / (entry["sessionId"] + ".jsonl")).is_file():
            raise ValueError("Falta la conversación original de Claude")
    elif agent == "codex":
        dbpath = Path.home() / ".codex/state_5.sqlite"
        with sqlite3.connect("file:" + str(dbpath) + "?mode=ro", uri=True) as db:
            row = db.execute("SELECT rollout_path FROM threads WHERE id = ?", (entry["sessionId"],)).fetchone()
        if row is None or not Path(row[0]).is_file():
            raise ValueError("No se puede comprobar la sesión original de Codex")
    elif agent == "agy":
        if not (Path.home() / ".gemini/antigravity-cli/conversations" / (entry["sessionId"] + ".db")).is_file():
            raise ValueError("Falta la conversación original de Antigravity")
    else:
        raise ValueError("IA desconocida en el manifiesto: " + str(agent))


# ---------------------------------------------------------------- lectura de procesos

class ProcReaders:
    """Todo lo que la detección y la guarda leen del sistema. Solo lectura.

    Las pruebas pasan un sustituto con los mismos métodos, construido desde el fixture compartido.
    """

    def __init__(self, home=None, proc="/proc"):
        self.home = str(home or Path.home())
        self.proc = proc
        self.claude_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(self.home, ".claude")

    def process_table(self):
        """{pid: {pid, ppid, uid, argv}}, o None si no se puede leer /proc."""
        try:
            names = os.listdir(self.proc)
        except OSError:
            return None
        table = {}
        for name in names:
            if not name.isdigit():
                continue
            base = os.path.join(self.proc, name)
            try:
                with open(os.path.join(base, "stat"), "rb") as handle:
                    stat = handle.read().decode(errors="replace")
                ppid = int(stat.rsplit(")", 1)[1].split()[1])
                uid = None
                with open(os.path.join(base, "status"), "rb") as handle:
                    for line in handle.read().decode(errors="replace").splitlines():
                        if line.startswith("Uid:"):
                            uid = int(line.split()[2])  # efectivo, como `ps -o uid=`
                            break
                with open(os.path.join(base, "cmdline"), "rb") as handle:
                    argv = [a for a in handle.read().decode(errors="replace").split("\0") if a]
            except (OSError, ValueError, IndexError):
                continue
            table[int(name)] = {"pid": int(name), "ppid": ppid, "uid": uid, "argv": argv}
        return table

    def open_files(self, pid):
        """Rutas abiertas por `pid`, o None si no se dejan leer."""
        base = os.path.join(self.proc, str(pid), "fd")
        try:
            fds = os.listdir(base)
        except OSError:
            return None
        paths = []
        for fd in fds:
            try:
                paths.append(os.readlink(os.path.join(base, fd)))
            except OSError:
                continue
        return paths

    def cwd(self, pid):
        try:
            return os.readlink(os.path.join(self.proc, str(pid), "cwd"))
        except OSError:
            return None

    def read_text(self, path, limit=65536):
        try:
            with open(path, "rb") as handle:
                return handle.read(limit).decode(errors="replace")
        except OSError:
            return None

    def list_dir(self, path):
        try:
            return os.listdir(path)
        except OSError:
            return []

    def realpath(self, path):
        return os.path.realpath(path)

    def locked(self, path):
        return kernel_locked(Path(path))


def kernel_locked(path):
    """Si alguien tiene el cerrojo del kernel sobre `path`. Que el fichero exista no prueba nada."""
    if lock_owners(path):
        return True
    try:
        with path.open("rb") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(handle, fcntl.LOCK_UN)
    except OSError:
        pass
    return False


def ficha_dirs(readers, uid):
    """Dónde puede estar la ficha de un Claude de este uid. /root solo si la raíz es de root."""
    dirs = [os.path.join(readers.claude_dir, "sessions")]
    root_dir = "/root/.claude/sessions"
    if uid == 0 and root_dir not in dirs:
        dirs.append(root_dir)
    return dirs


def read_ficha(readers, pid, uid):
    for directory in ficha_dirs(readers, uid):
        text = readers.read_text(os.path.join(directory, str(pid) + ".json"))
        if text is None:
            continue
        try:
            ficha = json.loads(text)
        except ValueError:
            continue
        if isinstance(ficha, dict):
            return ficha
    return None


def provider_of(proc):
    """Qué IA es este proceso por su línea de órdenes, o None (regla 2 del contrato).

    La ficha de Claude nunca clasifica: solo da identidad a un proceso que ya es Claude. Con la
    regla vieja («tiene ficha y algún argumento contiene claude») un pid reciclado por
    `vim ~/.claude/CLAUDE.md` pasaba por Claude y bloqueaba la reanudación.
    """
    argv = proc.get("argv") or []
    if not argv:
        return None
    argv0 = argv[0]
    base = os.path.basename(argv0)
    rest = argv[1:]
    node = bool(NODE.match(base))
    if (base == "claude" or "/claude/versions/" in argv0
            or (node and any("@anthropic-ai/claude-code" in a or os.path.basename(a) == "claude" for a in rest))):
        return "claude"
    if base.startswith("codex") or (node and any("@openai/codex" in a or os.path.basename(a) in ("codex", "codex.js") for a in rest)):
        return "codex"
    if base in ("agy", "antigravity"):
        return "agy"
    if base == "grok" or base.startswith("grok-"):
        return "grok"
    return None


def subtree(table, root_pid):
    """Descendientes de `root_pid` (incluido), en anchura. Nunca con pgrep ni por el entorno."""
    children = {}
    for proc in table.values():
        children.setdefault(proc["ppid"], []).append(proc["pid"])
    if root_pid not in table:
        return []
    seen, order, queue = {root_pid}, [root_pid], deque([(root_pid, 0)])
    while queue and len(order) < MAX_NODES:
        pid, depth = queue.popleft()
        if depth >= MAX_DEPTH:
            continue
        for child in sorted(children.get(pid, [])):
            if child in seen or len(order) >= MAX_NODES:
                continue
            seen.add(child)
            order.append(child)
            queue.append((child, depth + 1))
    return order


def _options(argv):
    """argv[1:] hasta el primer `--`: lo de detrás es texto para la IA, no opciones."""
    rest = list(argv[1:])
    return rest[:rest.index("--")] if "--" in rest else rest


def _canonical_id(value):
    return value.lower() if UUID_CI.match(value) else value


def _argv_id(argv, names, valid):
    """El id que da la línea de órdenes, con la regla 4 del contrato, o None.

    `<opción> <valor>` solo si el valor no empieza por `-`; `<opción>=<valor>` solo en las largas.
    Se reúnen todos los valores: si alguno no es válido o hay más de uno distinto (por ejemplo
    `--resume X --session-id Y`), la línea de órdenes no da id. Ante la duda, no se da id.
    """
    options, values = _options(argv), []
    for index, token in enumerate(options):
        for name in names:
            if token == name:
                if index + 1 < len(options) and not options[index + 1].startswith("-"):
                    values.append(options[index + 1])
            elif name.startswith("--") and token.startswith(name + "="):
                values.append(token[len(name) + 1:])
    if not values or not all(valid(value) for value in values):
        return None
    ids = {_canonical_id(value) for value in values}
    return ids.pop() if len(ids) == 1 else None


def _codex_argv_id(argv):
    """El `<uuid>` que sigue al primer `resume` antes de `--`, o None."""
    options = _options(argv)
    if "resume" not in options:
        return None
    index = options.index("resume") + 1
    return options[index].lower() if index < len(options) and UUID_CI.match(options[index]) else None


def _rollout_id(path):
    if "/.codex/sessions/" not in path:
        return None
    name = os.path.basename(path)
    if not (name.startswith("rollout-") and name.endswith(".jsonl")):
        return None
    found = UUID_ANY.findall(name)
    return found[-1] if found else None


def codex_extra(argv):
    """Modelo y esfuerzo de razonamiento de la línea de órdenes, para relanzar igual."""
    extra = {}
    for index, token in enumerate(argv[:-1]):
        if token == "-m":
            extra["model"] = argv[index + 1]
        if token == "-c" and argv[index + 1].startswith("model_reasoning_effort="):
            raw = argv[index + 1].split("=", 1)[1]
            try:
                extra["reasoningEffort"] = json.loads(raw)
            except ValueError:
                extra["reasoningEffort"] = raw
    return extra


def detect_agent(pane_pid, table, readers, pane_current_path=None):
    """Qué IA corre bajo el shell de un panel, con el criterio común.

    Devuelve {provider, session_id, cwd, as_root, source, pid, status, version, argv, cause} o
    {"cause": "sin_ia" | "identidad_ambigua" | "panel_muerto"}. `cause` es "sin_id" cuando hay IA
    pero no conversación. "panel_muerto": el shell del panel ya no está en la tabla de procesos.
    """
    pids = subtree(table, pane_pid)
    if not pids:
        return {"cause": "panel_muerto"}
    inside = set(pids)
    providers = {pid: provider_of(table[pid]) for pid in pids}

    def has_provider_ancestor(pid):
        parent, steps = table[pid]["ppid"], 0
        while parent in inside and steps <= MAX_DEPTH:
            if providers.get(parent):
                return True
            if parent == pane_pid:
                break
            parent, steps = table[parent]["ppid"], steps + 1
        return False

    roots = [pid for pid in pids if providers.get(pid) and not has_provider_ancestor(pid)]
    if not roots:
        return {"cause": "sin_ia"}
    if len(roots) > 1:
        return {"cause": "identidad_ambigua"}
    root = roots[0]
    proc = table[root]
    provider = providers[root]
    argv = proc.get("argv") or []
    session_id, source, cwd, status, version = None, None, None, None, None

    if provider == "claude":
        ficha = read_ficha(readers, root, proc.get("uid"))
        found = ficha.get("sessionId") if ficha else None
        # Claude escribe su propio pid dentro de la ficha. Si es otro, el fichero es de otro proceso
        # (copiado o restaurado) y su conversación sería la de otro. Sin pid dentro (fichas
        # antiguas), vale.
        if isinstance(found, str) and SESSION_ID.match(found) and ficha.get("pid") in (None, root, str(root)):
            session_id, source = _canonical_id(found), "ficha"
            cwd = ficha.get("cwd") if isinstance(ficha.get("cwd"), str) else None
            status, version = ficha.get("status"), ficha.get("version")
        else:
            session_id = _argv_id(argv, ("--resume", "-r", "--session-id"), UUID_CI.match)
            source = "argv" if session_id else None
    elif provider == "codex":
        branch = [root] + [pid for pid in pids if pid != root and providers.get(pid) == "codex" and _descends(table, pid, root)]
        opened = {}
        for pid in branch:
            for path in readers.open_files(pid) or []:
                found = _rollout_id(path)
                if found:
                    opened.setdefault(found.lower(), path)
        resume = next((found for found in (_codex_argv_id(table[pid].get("argv") or []) for pid in branch) if found), None)
        if len(opened) == 1 or (len(opened) > 1 and resume in opened):
            # Con varios rollouts abiertos (un `codex exec` lanzado por la propia sesión abre el
            # suyo, más reciente) solo vale el que coincide con su `resume <uuid>`. Nunca «el más
            # reciente» ni argv a solas: pisaría el id bueno guardado cuando solo había uno.
            session_id = resume if len(opened) > 1 else next(iter(opened))
            source = "rollout"
            first = (readers.read_text(opened[session_id]) or "").split("\n", 1)[0]
            try:
                cwd = (json.loads(first).get("payload") or {}).get("cwd") or None
            except (ValueError, AttributeError):
                cwd = None
        elif not opened:
            session_id = resume
            source = "argv" if session_id else None
    elif provider == "agy":
        session_id = _argv_id(argv, ("--conversation",), SESSION_ID.match)
        source = "argv" if session_id else None
    elif provider == "grok":
        session_id = _argv_id(argv, ("-r", "--resume"), SESSION_ID.match)
        source = "argv" if session_id else None

    cwd = cwd or readers.cwd(root) or pane_current_path
    if cwd:
        cwd = readers.realpath(cwd)
    return {"provider": provider, "session_id": session_id, "cwd": cwd, "as_root": proc.get("uid") == 0,
            "source": source, "pid": root, "status": status, "version": version, "argv": argv,
            "cause": None if session_id else "sin_id"}


def _descends(table, pid, ancestor):
    seen = set()
    while pid in table and pid not in seen:
        seen.add(pid)
        pid = table[pid]["ppid"]
        if pid == ancestor:
            return True
    return False


def detect_session(panes, table, readers):
    """Una sesión con varios paneles: cuenta el único panel con IA; con IA en más de uno, ambigua.

    Todos los paneles muertos (o sin su shell en la tabla) dan `panel_muerto`: no dice que la IA se
    cerrara, así que lo guardado no se toca.
    """
    found, alive = [], False
    for pane in panes:
        if pane.get("dead"):
            continue
        result = detect_agent(pane["pane_pid"], table, readers, pane.get("cwd"))
        if result.get("cause") == "panel_muerto":
            continue
        alive = True
        if result.get("cause") == "identidad_ambigua":
            return result
        if result.get("provider"):
            found.append(result)
    if not alive:
        return {"cause": "panel_muerto"}
    if not found:
        return {"cause": "sin_ia"}
    if len(found) > 1:
        return {"cause": "identidad_ambigua"}
    return found[0]


# ---------------------------------------------------------------- guarda

def guard(provider, session_id, readers):
    """0 libre, 1 abierta en otra parte, 2 no se puede comprobar. Solo el 0 permite reanudar."""
    if not SESSION_ID.match(session_id or "") or provider not in RESUME:
        return 2
    table = readers.process_table()
    if provider == "claude":
        if table is None:
            return 2
        for directory in ficha_dirs(readers, 0):
            for name in readers.list_dir(directory):
                if not name.endswith(".json") or not name[:-5].isdigit():
                    continue
                pid = int(name[:-5])
                proc = table.get(pid)
                if proc is None:
                    continue
                try:
                    ficha = json.loads(readers.read_text(os.path.join(directory, name)) or "")
                except ValueError:
                    continue
                # Criterio estricto de «es Claude» (el de agent_guard.py): un vim con CLAUDE.md
                # en un pid reciclado no bloquea. El pid interior de la ficha no se mira: ante la
                # duda, la guarda bloquea.
                if isinstance(ficha, dict) and ficha.get("sessionId") == session_id and provider_of(proc) == "claude":
                    return 1
        return 0
    if provider == "codex":
        if table is None:
            return 2
        for pid in table:
            if any(_rollout_id(path) == session_id for path in readers.open_files(pid) or []):
                return 1
        lock = os.path.join(readers.home, ".codex/thread-writer-locks", session_id + ".lock")
        return 1 if readers.locked(lock) else 0
    if provider == "agy":
        lock = os.path.join(readers.home, ".gemini/antigravity-cli/presence", session_id + ".lock")
        if readers.locked(lock):
            return 1
        if table and any(provider_of(p) == "agy" and session_id in p["argv"] for p in table.values()):
            return 1
        return 0
    if table is None:
        return 2
    return 1 if any(provider_of(p) == "grok" and session_id in p["argv"] for p in table.values()) else 0


def processes():
    """(pid, argv) de cada proceso que se deja leer."""
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            argv = Path("/proc", pid, "cmdline").read_bytes().decode(errors="replace").split("\0")
        except OSError:
            continue
        if argv and argv[0]:
            yield int(pid), [a for a in argv if a]


def native_lock_path(entry):
    if entry["agent"] == "codex":
        return Path.home() / ".codex/thread-writer-locks" / (entry["sessionId"] + ".lock")
    return Path.home() / ".gemini/antigravity-cli/presence" / (entry["sessionId"] + ".lock")


def lock_owners(path):
    """PIDs holding a kernel lock on `path`. An existing lock file alone proves nothing."""
    try:
        stat = path.stat()
    except FileNotFoundError:
        return []
    target = (os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino)
    owners = []
    try:
        lines = Path("/proc/locks").read_text().splitlines()
    except OSError:
        return []
    for line in lines:
        fields = line.split()
        for index, value in enumerate(fields):
            parts = value.split(":")
            if len(parts) != 3:
                continue
            try:
                identity = (int(parts[0], 16), int(parts[1], 16), int(parts[2]))
            except ValueError:
                continue
            if identity == target:
                owners.append(int(fields[index - 1]))
    return sorted(set(owners))


def native_session_available(entry, readers=None):
    """False mientras la conversación sigue abierta en otra parte (o no se puede saber)."""
    agent = entry.get("agent")
    if agent == "command":
        return True
    if agent in RESUME:
        return guard(agent, entry.get("sessionId"), readers or ProcReaders()) == 0
    # Entradas antiguas sin IA conocida: solo el cerrojo nativo.
    return not kernel_locked(native_lock_path(entry))


# ---------------------------------------------------------------- tmux

def tmux(socket, *args, check=True):
    # Siempre -L: sin él, dentro de un panel tmux se hablaría con el servidor de $TMUX.
    # `-L default` es el servidor por defecto.
    return subprocess.run(["tmux", "-L", socket, *args],
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check, timeout=15)


# El último campo es el pid del **servidor** tmux: si cambia entre dos vueltas, el servidor se
# reinició (D6, `missing_is_deliberate`).
PANE_FORMAT = "\t".join(("#{session_name}", "#{session_id}", "#{window_index}", "#{pane_id}", "#{pane_pid}",
                         "#{pane_dead}", "#{pane_current_path}", "#{pane_current_command}", "#{pid}"))

# Lo que dice `tmux list-sessions` cuando en ese socket no hay servidor (D4).
NO_SERVER = ("no server running", "error connecting", "No such file")


def live_sessions(socket):
    """{sesión: [paneles]} del servidor tmux `socket`, con **todos** los paneles de cada sesión."""
    result = tmux(socket, "list-panes", "-a", "-F", PANE_FORMAT, check=False)
    out = {}
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) not in (8, 9):
            continue
        name, session_id, window_index, pane_id, pane_pid, dead, cwd, command = fields[:8]
        try:
            pid = int(pane_pid)
        except ValueError:
            continue
        pane = {"session_id": session_id, "window_index": window_index, "pane_id": pane_id,
                "pane_pid": pid, "dead": dead == "1", "cwd": cwd, "command": command}
        if len(fields) == 9 and fields[8].isdigit():
            pane["server_pid"] = fields[8]
        out.setdefault(name, []).append(pane)
    return out


def server_running(socket):
    """True si el servidor tmux de `socket` existe, False si seguro que no, None si no se sabe.

    Solo False permite poner opciones de servidor (D4): con la duda se trata como vivo.
    """
    try:
        result = tmux(socket, "list-sessions", "-F", "#{pid}", check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode == 0:
        return True
    text = (result.stderr or "") + (result.stdout or "")
    return False if any(marker in text for marker in NO_SERVER) else None


# ---------------------------------------------------------------- acciones

def snapshot(data, manifest_path, readers=None):
    """Aprende las sesiones vivas. Añade las nuevas, refresca las conocidas y nunca borra.

    Lo aprendido se fusiona sobre el manifiesto que hay en el disco en ese momento.
    """
    readers = readers or ProcReaders()
    table = readers.process_table() or {}
    learned, live_by_socket, servers = [], {}, {}
    for socket in watched_sockets(data):
        sessions = live_sessions(socket)
        live_by_socket[socket] = sorted(sessions)
        pids = {pane["server_pid"] for panes in sessions.values() for pane in panes if pane.get("server_pid")}
        if len(pids) == 1:
            servers[socket] = pids.pop()
        for name, panes in sessions.items():
            try:
                found = detect_session(panes, table, readers)
            except Exception as error:  # noqa: BLE001 - una sesión rara no para la vuelta
                warn_once(("detectar", socket, name, str(error)), "No se pudo leer la sesión " + name + ": " + str(error))
                continue
            if not found.get("provider") or not found.get("session_id"):
                # Sin IA, ambigua o sin id: lo guardado no se toca.
                continue
            fresh = {"agent": found["provider"], "sessionId": found["session_id"],
                     "cwd": found["cwd"] or panes[0].get("cwd"), "source": found["source"], "asRoot": found["as_root"]}
            if found["provider"] == "codex":
                fresh.update(codex_extra(found.get("argv") or []))
            learned.append((socket, name, fresh))

    primary = data.get("tmuxSocket") or "default"
    seen = {"bootId": boot_id(), "at": time.time(), "sessions": live_by_socket.get(primary, [])}
    if len(live_by_socket) > 1:
        seen["sockets"] = live_by_socket
    if servers:
        seen["servers"] = servers

    def merge(current):
        changed = False
        known = {entry_key(current, e): e for e in current["windows"]}
        for socket, name, fresh in learned:
            entry = known.get((socket, name))
            if entry is None:
                entry = {"name": name, "tmux": name, "tmuxSocket": socket, "workspace": current.get("workspace", ""), **fresh}
                current["windows"].append(entry)
                known[(socket, name)] = entry
                changed = True
                print("Aprendida " + name + " (" + fresh["agent"] + " " + fresh["sessionId"][:8] + ")", flush=True)
            elif any(entry.get(k) != v for k, v in fresh.items()):
                entry.update(fresh)
                changed = True
                print("Actualizada " + name, flush=True)
        old = current.get("seen") or {}
        # `at` solo no justifica reescribir el manifiesto cada 15 segundos.
        if {k: v for k, v in old.items() if k != "at"} != {k: v for k, v in seen.items() if k != "at"}:
            current["seen"] = seen
            changed = True
        return changed

    return update_manifest(manifest_path, merge, fallback=data)


def missing_is_deliberate(data, missing):
    """Un cierre a mano: mismo arranque, **el mismo** servidor tmux sigue vivo y solo faltan algunas
    ventanas de ese servidor (la marca de cierre deliberado de D6)."""
    seen = data.get("seen") or {}
    if seen.get("bootId") != boot_id():
        return False                      # reinicio: murió todo, se devuelve todo
    by_socket = {}
    for entry in missing:
        by_socket.setdefault(entry_socket(data, entry), []).append(entry)
    for socket, gone in by_socket.items():
        result = tmux(socket, "list-sessions", "-F", "#{pid}", check=False)
        if result.returncode != 0:
            return False                  # el propio servidor tmux cayó: se devuelve todo
        before = (seen.get("servers") or {}).get(socket)
        now = {line.strip() for line in (result.stdout or "").splitlines() if line.strip()}
        if before and now and now != {before}:
            # Otro servidor en el mismo socket: el de antes cayó y alguien (UniConnect desde un
            # escritorio, por ejemplo) ya levantó uno nuevo con alguna ventana. Lo que falta murió
            # con el viejo; darlo por cerrado a mano lo olvidaría para siempre.
            return False
        total = sum(1 for entry in data["windows"] if entry_socket(data, entry) == socket)
        if len(gone) >= total:
            return False
    return True


def launch_command(manifest_path, entry, socket):
    return shlex.join([sys.executable, str(Path(__file__).resolve()), "--manifest", str(manifest_path),
                       "--socket", socket, "launch", entry["tmux"]])


def ensure_windows(data, manifest_path):
    """Crea las ventanas que faltan. Nunca sustituye ni reconfigura una sesión que ya existe.

    Cada entrada va por separado: una rota se apunta y se sigue con la siguiente.
    """
    # Un `has-session` por ventana antes de tocar nada decide qué falta.
    exists = {}
    for entry in data["windows"]:
        key = entry_key(data, entry)
        try:
            exists[key] = tmux(key[0], "has-session", "-t", "=" + entry["tmux"], check=False).returncode == 0
        except (OSError, subprocess.SubprocessError) as error:
            warn_once(("has-session", key, str(error)), "No se pudo consultar " + entry["tmux"] + ": " + str(error))
            exists[key] = None
    missing = [entry for entry in data["windows"] if exists.get(entry_key(data, entry)) is False]
    if missing and missing_is_deliberate(data, missing):
        gone = {entry_key(data, entry) for entry in missing}
        for entry in missing:
            print("Olvidada " + entry["tmux"] + ": se cerró a propósito", flush=True)
        data["windows"] = [e for e in data["windows"] if entry_key(data, e) not in gone]

        def forget(current):
            before = len(current["windows"])
            current["windows"] = [e for e in current["windows"] if entry_key(current, e) not in gone]
            return len(current["windows"]) != before

        update_manifest(manifest_path, forget, fallback=data)
    for entry in list(data["windows"]):
        try:
            ensure_one(data, manifest_path, entry, exists.get(entry_key(data, entry)))
        except Exception as error:  # noqa: BLE001 - una entrada rota no deja sin vigilar a las demás
            warn_once(("ensure", entry.get("tmux"), str(error)),
                      "La recuperación necesita atención en " + str(entry.get("tmux")) + ": " + str(error))
        else:
            # Si vuelve a fallar después de arreglarse, se vuelve a contar.
            _warned.difference_update({k for k in _warned if k[:2] == ("ensure", entry.get("tmux"))})


def ensure_one(data, manifest_path, entry, exists):
    if exists is None:
        return
    socket = entry_socket(data, entry)
    target = "=" + entry["tmux"]
    launch = launch_command(manifest_path, entry, socket)
    if exists:
        owner = tmux(socket, "show-option", "-v", "-t", target + ":", "@uniconnect_session_id", check=False).stdout.strip()
        if not owner:
            # Una sesión que no creó el supervisor: se vigila, pero nunca se le cambian opciones ni
            # se reabre su panel.
            if not entry.get("adopted"):
                entry["adopted"] = True
                key = entry_key(data, entry)

                def adopt(current):
                    for other in current["windows"]:
                        if entry_key(current, other) == key and not other.get("adopted"):
                            other["adopted"] = True
                            return True
                    return False

                update_manifest(manifest_path, adopt, fallback=data)
            return
        if owner not in {entry.get("sessionId", ""), entry.get("tmuxOwner", "")}:
            warn_once(("owner", socket, entry["tmux"], owner),
                      "Se salta " + entry["tmux"] + ": la sesión tmux es de otro dueño (" + owner + ")")
            return
        if entry.get("adopted"):
            return
        if not entry.get("tmuxOwner"):
            # La creó un supervisor anterior a `tmuxOwner` (su dueño es el sessionId de entonces).
            # Se fija ya, mientras coinciden: el primer /clear que cambie sessionId la dejaría como
            # «de otro dueño» y el supervisor dejaría de reabrir su panel.
            _record_owner(data, manifest_path, entry, owner)
        panes = tmux(socket, "list-panes", "-t", target + ":", "-F", "#{pane_id}\t#{pane_dead}").stdout.splitlines()
        if len(panes) == 1 and panes[0].endswith("\t1"):
            # Sin -k: tmux se niega a sustituir un panel vivo si cambia durante esta comprobación.
            tmux(socket, "respawn-pane", "-t", panes[0].split("\t")[0], "exec " + launch)
            print("Reabierta " + entry["tmux"], flush=True)
        return
    verify_session(entry)
    command_for(entry)
    create = ["new-session", "-d", "-s", entry["tmux"], "-n", entry.get("name", entry["tmux"]),
              "-c", entry["cwd"], "-x", "160", "-y", "45", "exec " + launch]
    # D4: una opción de servidor (-s) afecta a todas las sesiones de ese tmux, a menudo un 3.2a con
    # otras IA dentro; un set-clipboard en caliente mató el tmux del Mac con 27 IA el 23-09. Así que
    # set-clipboard off (el arreglo del fallo de tmux viejo con ncurses nuevo al exportar por OSC 52)
    # solo va con el new-session que **arranca** el servidor: si ya existía, o no se sabe, nada.
    if server_running(socket) is False:
        create += [";", "set-option", "-s", "set-clipboard", "off"]
    result = tmux(socket, *create, check=False)
    if result.returncode != 0:
        if tmux(socket, "has-session", "-t", target, check=False).returncode == 0:
            return
        raise RuntimeError("tmux no pudo crear " + entry["tmux"] + ": " + result.stderr.strip())
    owner = entry.get("sessionId", "")
    # Solo opciones de la sesión y la ventana recién creadas (-t): nunca del servidor.
    for option, value in (("@uniconnect_session_id", owner),
                          ("@uniconnect_workspace", entry.get("workspace", "")), ("mouse", "on")):
        tmux(socket, "set-option", "-t", target + ":", option, value)
    tmux(socket, "set-window-option", "-t", target + ":", "automatic-rename", "off")
    tmux(socket, "set-window-option", "-t", target + ":", "remain-on-exit", "on")
    _record_owner(data, manifest_path, entry, owner)
    print("Creada " + entry["tmux"], flush=True)


def _record_owner(data, manifest_path, entry, owner):
    """Apunta en el manifiesto que esta entrada es del supervisor, con el dueño que lleva en tmux."""
    key = entry_key(data, entry)

    def own(current):
        for other in current["windows"]:
            if entry_key(current, other) == key:
                if other.get("tmuxOwner") == owner and "adopted" not in other:
                    return False
                other.pop("adopted", None)
                other["tmuxOwner"] = owner
                return True
        return False

    entry.pop("adopted", None)
    entry["tmuxOwner"] = owner
    update_manifest(manifest_path, own, fallback=data)


def launch(entry, manifest_path):
    while True:
        try:
            return launch_once(entry, manifest_path)
        except Exception as error:  # noqa: BLE001 - the window must never die silently
            print("No se pudo lanzar: " + str(error) + ". Reintento en 30 segundos.", flush=True)
            time.sleep(30)


def launch_once(entry, manifest_path):
    verify_session(entry)
    lease_dir = manifest_path.parent / "launcher-locks"
    lease_dir.mkdir(mode=0o700, exist_ok=True)
    with (lease_dir / ((entry.get("sessionId") or entry["tmux"]) + ".lock")).open("a") as lease:
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Otro lanzador de UniConnect ya lleva esta ventana")
        while True:
            waiting = False
            while not native_session_available(entry):
                if not waiting:
                    print("La sesión original sigue abierta. Esta ventana la recuperará cuando salga.", flush=True)
                    waiting = True
                time.sleep(5)
            if waiting:
                print("La sesión original se ha cerrado. Recuperando el mismo historial…", flush=True)
            verify_session(entry)
            if entry["agent"] == "claude":
                trust_folder_for_claude(entry["cwd"])
            child = subprocess.Popen(command_for(entry), cwd=entry["cwd"], env=environment_for(entry))
            while True:
                try:
                    code = child.wait(); break
                except KeyboardInterrupt:
                    continue
            if code:
                print("El cliente ha terminado con código " + str(code) + ". Reintento en 30 segundos; el historial se conserva.", flush=True)
                time.sleep(30)
                continue
            try:
                input("Sesión cerrada. Pulsa Intro para recuperar el mismo historial: ")
            except (EOFError, KeyboardInterrupt):
                return


def status(data):
    live = {socket: live_sessions(socket) for socket in watched_sockets(data)}
    rows = []
    for entry in data["windows"]:
        socket = entry_socket(data, entry)
        panes = live.get(socket, {}).get(entry["tmux"])
        alive = panes is not None
        known = entry.get("agent") in RESUME
        rows.append({"tmux": entry["tmux"], "socket": socket, "agent": entry.get("agent"), "sessionId": entry.get("sessionId"),
                     "source": entry.get("source"), "adopted": bool(entry.get("adopted")),
                     "alive": alive, "dead_pane": all(p["dead"] for p in panes) if alive else None,
                     "open_elsewhere": (not native_session_available(entry)) if known else None,
                     "resumeCommand": shell_command_for(entry)})
    print(json.dumps({"tmuxSocket": data["tmuxSocket"], "tmuxSockets": watched_sockets(data), "seen": data.get("seen"),
                      "windows": rows}, indent=2, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--socket", help="servidor tmux de la ventana (launch y forget)")
    parser.add_argument("action", choices=("validate", "snapshot", "ensure", "supervise", "launch", "status", "forget"))
    parser.add_argument("name", nargs="?")
    args = parser.parse_args()
    manifest_path = args.manifest.resolve()
    data = load_manifest(manifest_path)

    def matches(current, entry):
        return entry["tmux"] == args.name and (args.socket is None or entry_socket(current, entry) == args.socket)

    if args.action == "validate":
        for entry in data["windows"]:
            verify_session(entry); command_for(entry)
        print("Comprobadas " + str(len(data["windows"])) + " sesiones; no se ha arrancado nada.")
    elif args.action == "snapshot":
        snapshot(data, manifest_path)
    elif args.action == "launch":
        entry = next((w for w in data["windows"] if matches(data, w)), None)
        if entry is None:
            raise ValueError("Esa ventana no está en el manifiesto")
        launch(entry, manifest_path)
    elif args.action == "forget":
        def forget(current):
            before = len(current["windows"])
            current["windows"] = [w for w in current["windows"] if not matches(current, w)]
            return len(current["windows"]) != before
        update_manifest(manifest_path, forget)
        print("Olvidada " + str(args.name), flush=True)
    elif args.action == "status":
        status(data)
    elif args.action == "ensure":
        ensure_windows(data, manifest_path)
    else:
        while True:
            supervise_once(manifest_path)
            time.sleep(15)


def supervise_once(manifest_path):
    """Una vuelta de `supervise`. Relee el manifiesto: un `forget` o una edición a mano cuentan ya."""
    try:
        data = load_manifest(manifest_path)
        ensure_windows(data, manifest_path)
        snapshot(data, manifest_path)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("La recuperación necesita atención: " + str(error), file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
