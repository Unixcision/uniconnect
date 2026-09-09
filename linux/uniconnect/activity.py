"""Actividad de agentes por ventana (contrato activity.v1) y tipo de aviso.

Sin GTK: el resolutor recibe hechos con marca de tiempo (salida, teclado,
redimensionado, sondeo tmux, hooks) y decide `working`, `waiting`, `idle` o
`unknown` por ventana. El texto de pantalla que inspecciona para detectar una
pregunta de permiso no se registra ni sale de este módulo: solo el veredicto.
"""

from __future__ import annotations

import math
import re
import shlex
import time
from dataclasses import dataclass, field
from typing import Callable, Iterable

STATES = ("working", "waiting", "idle", "unknown")
SOURCES = ("hooks", "title", "screen", "output")
AGENTS = ("claude", "codex", "gemini", "agy")
KINDS = ("attention", "finished", "info")
PRIORITY = {"waiting": 3, "working": 2, "idle": 1, "unknown": 0}

SHELLS = frozenset({"sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "login", "tmux", "ssh", "sshpass"})
LIVE_HELPERS = frozenset({"node", "python3", "python", "bun", "deno"})

OUTPUT_WORKING_SECONDS = 3.0
OUTPUT_IDLE_SECONDS = 5.0
SCREEN_QUIET_SECONDS = 1.0
ECHO_SECONDS = 0.25
RESIZE_SECONDS = 0.5
HOOK_TTL_SECONDS = 120.0
SCREEN_LINES = 12

_ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]|[\x00-\x08\x0b-\x1f\x7f]")
PERMISSION_PATTERNS = tuple(re.compile(pattern, re.IGNORECASE) for pattern in (
    r"do you want to proceed", r"❯\s*1\.\s*yes", r"esc to cancel",            # Claude Code
    r"\b(?:allow|approve)\b.*\[y/n\]", r"would you like to run",               # Codex
    r"allow execution", r"apply this change",                                  # Gemini / Agy
))
_ATTENTION_EVENTS = frozenset({"permission_prompt", "elicitation_dialog", "elicitation_url_dialog",
                               "agent_needs_input", "permissionrequest", "needsinput", "needs_input"})
_FINISHED_EVENTS = frozenset({"idle_prompt", "agent_completed", "stop", "idle", "agent-turn-complete",
                              "turn_complete", "turncomplete"})


@dataclass(frozen=True)
class AgentActivity:
    """Estado publicado de una ventana; `since` es la época del último cambio de `state`."""

    state: str = "unknown"
    source: str = "output"
    agent: str | None = None
    since: float = 0.0

    def snapshot(self) -> dict:
        return {"state": self.state, "source": self.source, "agent": self.agent, "since": int(self.since)}


def aggregate_state(states: Iterable[str]) -> str:
    """Agregado por caja: waiting > working > idle > unknown."""
    return max(states, key=lambda state: PRIORITY.get(state, 0), default="unknown")


def strip_ansi(text: str) -> str:
    return _ANSI.sub("", text)


def permission_visible(lines: Iterable[str]) -> bool:
    """¿Hay una pregunta de permiso en las últimas líneas visibles? Solo devuelve el veredicto."""
    tail = [strip_ansi(line) for line in list(lines)[-SCREEN_LINES:]]
    return any(pattern.search(line) for line in tail for pattern in PERMISSION_PATTERNS)


def agent_from_command(command: str | None) -> tuple[str | None, bool, bool]:
    """(agente, es_shell, proceso_vivo_de_ia) a partir del comando en primer plano."""
    if not command:
        return None, False, False
    name = command.strip().rsplit("/", 1)[-1].lower()
    if name in SHELLS:
        return None, True, False
    for agent in AGENTS:
        if name == agent or name.startswith(agent + "-") or name.startswith(agent + "."):
            return agent, False, True
    return None, False, name in LIVE_HELPERS


def agent_from_title(title: str | None) -> str | None:
    """El título solo identifica: ✳ es Claude, braille es Codex. Nunca dice si trabaja o paró."""
    if not title:
        return None
    first = title.lstrip()[:1]
    if first == "✳":
        return "claude"
    if first and 0x2800 <= ord(first) <= 0x28FF:
        return "codex"
    return None


def title_shows_work(title: str | None) -> bool:
    """Un spinner braille al inicio del título (Codex trabajando) es evidencia positiva."""
    first = (title or "").lstrip()[:1]
    return bool(first) and 0x2800 <= ord(first) <= 0x28FF


def probe_script(socket_name: str) -> str:
    """Una sonda por socket tmux: sesión, pane, comando en primer plano, título y última actividad."""
    return (shlex.join(["tmux", "-L", socket_name, "list-panes", "-a", "-F",
                        "#{session_name}\t#{pane_id}\t#{pane_current_command}\t#{pane_title}\t#{window_activity}"])
            + " 2>/dev/null || true")


def parse_list_panes(output: str) -> dict[str, dict[str, tuple[str, str, float | None]]]:
    """`{sesión: {pane_id: (comando, título, window_activity)}}`, un dato por pane, sin mezclar."""
    result: dict[str, dict[str, tuple[str, str, float | None]]] = {}
    for line in (output or "").splitlines()[:4096]:
        parts = line.split("\t", 4)
        if len(parts) != 5 or not parts[0] or not re.fullmatch(r"%[0-9]{1,20}", parts[1]):
            continue
        session, pane, command, title, activity = parts
        try:
            stamp: float | None = float(activity) if activity.strip() else None
        except ValueError:
            stamp = None
        result.setdefault(session, {})[pane] = (command.strip(), title, stamp)
    return result


def select_pane(panes: dict[str, tuple] | None, pane_id: str | None) -> tuple[str, str, float | None] | None:
    """El pane guardado (`paneId` explícito, como MobilePTYProcess) o el único de la sesión; ambiguo → None."""
    if not panes:
        return None
    if isinstance(pane_id, str) and re.fullmatch(r"%[0-9]{1,20}", pane_id):
        return panes.get(pane_id)
    if len(panes) == 1:
        return next(iter(panes.values()))
    return None


@dataclass
class _Facts:
    last_output: float = -math.inf
    last_input: float = -math.inf
    last_resize: float = -math.inf
    window_activity: float | None = None
    command: str | None = None
    title: str = ""
    hook_state: str | None = None
    hook_agent: str | None = None
    hook_at: float = -math.inf
    alive: bool = False
    launched: str | None = None
    probe_missing: bool = False  # La sonda no encontró la sesión/pane: el agente lanzado ya no vale.
    screen_epoch: int = 0  # Cambia con cualquier salida, contada o no: la pantalla cambió.
    screen_checked_epoch: int = -1  # -1 = nunca leída, aparte del reloj de salida.
    screen_waiting: bool = False
    current: AgentActivity = field(default_factory=AgentActivity)


class ActivityResolver:
    """Máquina de estados por ventana; el reloj (época en segundos) se inyecta."""

    def __init__(self, *, clock: Callable[[], float] = time.time):
        self.clock = clock
        self.facts: dict[str, _Facts] = {}

    def _facts(self, window_id: str) -> _Facts:
        facts = self.facts.get(window_id)
        if facts is None:
            facts = self.facts[window_id] = _Facts()
        return facts

    # ----- hechos -----

    def note_output(self, window_id: str, now: float | None = None) -> bool:
        """Salida del PTY. El eco de teclado (250 ms) y el redibujado por tamaño (500 ms) no cuentan."""
        now = self.clock() if now is None else now
        facts = self._facts(window_id)
        facts.screen_epoch += 1
        if now - facts.last_input < ECHO_SECONDS or now - facts.last_resize < RESIZE_SECONDS:
            return False
        facts.last_output = now
        return True

    def note_input(self, window_id: str, now: float | None = None) -> None:
        self._facts(window_id).last_input = self.clock() if now is None else now

    def note_resize(self, window_id: str, now: float | None = None) -> None:
        facts = self._facts(window_id)
        facts.last_resize = self.clock() if now is None else now
        facts.screen_epoch += 1

    def note_probe(self, window_id: str, command: str | None, title: str | None = None,
                   window_activity: float | None = None) -> None:
        facts = self._facts(window_id)
        facts.command, facts.probe_missing = command, False
        if title is not None:
            facts.title = title
        if window_activity is not None:
            facts.window_activity = window_activity

    def note_hook(self, window_id: str, state: str, agent: str | None = None, now: float | None = None) -> None:
        """Informe de un hook del agente: running → working, needsInput → waiting, idle → idle."""
        mapped = {"running": "working", "working": "working", "needsinput": "waiting", "waiting": "waiting",
                  "idle": "idle"}.get(str(state).lower())
        if mapped is None:
            return
        facts = self._facts(window_id)
        facts.hook_state, facts.hook_at = mapped, self.clock() if now is None else now
        if agent in AGENTS:
            facts.hook_agent = agent

    def clear_probe(self, window_id: str) -> None:
        """La sonda falló o la sesión/pane ya no está: nada de lo sondeado sigue valiendo."""
        facts = self.facts.get(window_id)
        if facts is not None:
            facts.command, facts.title, facts.window_activity, facts.probe_missing = None, "", None, True

    def note_alive(self, window_id: str, alive: bool, launched: str | None = None) -> None:
        facts = self._facts(window_id)
        facts.alive = alive
        if launched is not None:
            facts.launched = launched if launched in AGENTS else None

    def forget(self, window_id: str) -> None:
        self.facts.pop(window_id, None)

    def current(self, window_id: str) -> AgentActivity:
        facts = self.facts.get(window_id)
        return facts.current if facts else AgentActivity()

    # ----- decisión -----

    def evaluate(self, window_id: str, now: float | None = None,
                 screen: Callable[[], Iterable[str] | None] | None = None) -> AgentActivity:
        """Aplica las reglas en orden y devuelve el estado; `screen` solo se lee con la salida quieta ≥ 1 s."""
        now = self.clock() if now is None else now
        facts = self._facts(window_id)
        previous = facts.current
        agent, shell, live = agent_from_command(facts.command)
        hook_fresh = facts.hook_state is not None and now - facts.hook_at < HOOK_TTL_SECONDS
        if not facts.alive or shell or facts.probe_missing:
            # Sin proceso vivo, con un shell delante o sin la sesión tmux sondeada nada
            # puede estar trabajando ni esperando, diga lo que diga el título o la pantalla.
            state, source, agent = "unknown", "output", None
        else:
            if agent is None and hook_fresh:
                agent = facts.hook_agent
            if agent is None:
                agent = agent_from_title(facts.title)
            if facts.command is None and agent is None and not facts.probe_missing:
                agent = facts.launched  # Sin sonda todavía (SSH recién abierta): lo que se lanzó.
            live = live or (facts.command is None and not facts.probe_missing and facts.alive and agent is not None)
            live = live and facts.alive
            last_output = facts.last_output
            if last_output == -math.inf and facts.window_activity is not None:
                last_output = facts.window_activity  # Sin datos del PTY, vale la marca de tmux.
            quiet = now - last_output
            if hook_fresh:
                state, source = facts.hook_state, "hooks"
            else:
                state = source = None
                if screen is not None and quiet >= SCREEN_QUIET_SECONDS:
                    if facts.screen_checked_epoch != facts.screen_epoch:
                        lines = screen()
                        facts.screen_checked_epoch = facts.screen_epoch
                        facts.screen_waiting = bool(lines) and permission_visible(lines)
                    if facts.screen_waiting:
                        state, source = "waiting", "screen"
                if state is None and title_shows_work(facts.title):
                    state, source = "working", "title"
                if state is None and quiet <= OUTPUT_WORKING_SECONDS:
                    state, source = "working", "output"
                if state is None and quiet > OUTPUT_IDLE_SECONDS and live:
                    state, source = "idle", "output"
                if state is None and OUTPUT_WORKING_SECONDS < quiet <= OUTPUT_IDLE_SECONDS and live \
                        and previous.state != "unknown":
                    state, source = previous.state, previous.source
                if state is None:
                    state, source = "unknown", "output"
        since = previous.since if state == previous.state and previous.since else now
        facts.current = AgentActivity(state=state, source=source, agent=agent, since=since)
        return facts.current

    def snapshot(self, window_id: str) -> dict:
        return self.current(window_id).snapshot()


# ----- tipo de aviso -----

def kind_from_hook(event: str | None) -> str | None:
    """`attention` para permiso/pregunta/entrada, `finished` para fin de turno, `info` para el resto."""
    if not event:
        return None
    key = str(event).strip().lower().replace(" ", "_")
    if key in _ATTENTION_EVENTS:
        return "attention"
    if key in _FINISHED_EVENTS:
        return "finished"
    return "info"


def notification_kind(hook_kind: str | None, activity_state: str | None) -> str:
    """El hook manda; sin hook, el estado de actividad de la ventana en ese instante."""
    if hook_kind in KINDS:
        return hook_kind
    return {"waiting": "attention", "idle": "finished"}.get(activity_state or "", "info")


def split_notify_payload(payload: str) -> tuple[str, str, str, str | None]:
    """`title|subtitle|body|kind`: el cuarto campo solo es `kind` si es válido; si no, sigue en el cuerpo."""
    parts = payload.split("|", 3)
    title = parts[0] if parts else ""
    subtitle = parts[1] if len(parts) > 1 else ""
    body = parts[2] if len(parts) > 2 else ""
    kind = None
    if len(parts) > 3:
        if parts[3].strip() in KINDS:
            kind = parts[3].strip()
        else:
            body = body + "|" + parts[3]
    return title, subtitle, body, kind


def activity_snapshot(monitor, window_id: str) -> dict:
    """Snapshot para el móvil desde el monitor del escritorio, o el valor por defecto sin monitor."""
    if monitor is None:
        return AgentActivity().snapshot()
    return monitor.activity(window_id).snapshot()


def workspace_activity(monitor, workspace: dict) -> dict:
    states = [activity_snapshot(monitor, record["id"])["state"] for record in workspace.get("windows", [])]
    return {"state": aggregate_state(states)}

