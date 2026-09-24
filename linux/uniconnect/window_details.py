"""«Detalles» de una ventana (window_details.v1): el mismo JSON para el modal, el móvil y la CLI.

Solo lectura: combina lo guardado con la última lectura viva de la sonda y deriva la orden
para reanudar la IA con la política sin preguntas del catálogo compartido. Nunca incluye la
orden de conexión, contraseñas ni credentialId.
"""

import ast
import datetime

from .agent_tree import AgentTree
from .resume_catalog import AgentResumeCatalog

AGENTS = ("claude", "codex", "agy", "grok")
DISPLAY_NAMES = {"claude": "Claude Code", "codex": "Codex", "agy": "Agy", "grok": "Grok"}
LIVE_REASONS = ("sin_ia", "identidad_ambigua", "sin_id")
SOURCE_LABELS = {"ficha": "Ficha de sesión de Claude", "rollout": "Registro abierto de Codex",
                 "argv": "Línea de órdenes del proceso (puede estar desfasada)", "hook": "Aviso del propio agente",
                 "manifiesto": "Supervisor del servidor", "registro": "Guardado en UniConnect"}
STATE_LABELS = {"activo": "En marcha", "guardado": "Guardada (no comprobada ahora)",
                "interrumpido": "Interrumpida: se reanudará al abrir"}
CHECKING = "Comprobando…"
UNREACHABLE = "No se pudo comprobar el servidor; se muestra lo guardado"


class WindowDetails:
    VERSION = 1

    @staticmethod
    def iso(value):
        """Fecha ISO 8601 UTC con ``Z``; acepta segundos epoch o una cadena ya formateada."""
        if value is None:
            return None
        if isinstance(value, str):
            return value
        moment = datetime.datetime.fromtimestamp(float(value), datetime.timezone.utc)
        return moment.strftime("%Y-%m-%dT%H:%M:%SZ")

    @staticmethod
    def host_label(value):
        """``user@host:port``; también convierte el hostLabel antiguo ``str(tupla)``."""
        if not isinstance(value, str) or not value:
            return None
        if value.startswith("("):
            try:
                parts = ast.literal_eval(value)
            except (ValueError, SyntaxError):
                return value
            if isinstance(parts, tuple) and len(parts) == 3 and all(isinstance(part, str) for part in parts):
                return "%s@%s:%s" % parts
        return value

    @classmethod
    def host(cls, workspace, connection=None):
        if workspace.get("kind") != "ssh":
            return None, None
        if connection is not None:
            user, hostname, port = connection.endpoint_key(resolve=False)
            return ({"user": user, "hostname": hostname, "port": int(port) if str(port).isdigit() else port},
                    "%s@%s:%s" % (user, hostname, port))
        # Bóveda cerrada: sin destino verificado, solo la etiqueta del perfil.
        return None, cls.host_label(workspace.get("hostLabel"))

    @staticmethod
    def resume(catalog, provider, session_id, cwd, as_root):
        if catalog is None or not session_id:
            return None
        try:
            argv, environment = catalog.no_prompt_resume(provider, session_id, as_root)
            return {"argv": argv, "environment": environment,
                    "command": AgentResumeCatalog.shell_command(argv, environment, cwd),
                    "no_prompt_verified": catalog.no_prompt(provider) is not None}
        except (KeyError, ValueError, TypeError):
            return None

    @classmethod
    def snapshot(cls, workspace, record, live, catalog, clock, *, connection=None):
        """JSON exacto de contracts/window-details-v1 para una ventana.

        ``live``: None (sin comprobar) o {"ok", "checked_at", "session", "error"} de AgentTree.
        """
        host, host_label = cls.host(workspace, connection)
        checked = live is not None
        ok = bool(live and live.get("ok"))
        entry = live.get("session") if ok else None
        tmux = None
        if record.get("tmux"):
            tmux = {"socket": AgentTree.socket_of(workspace, record), "session": record["tmux"],
                    "session_id": entry.get("session_id") if entry else None,
                    "pane_id": entry.get("pane_id") if entry else None, "live": bool(entry)}
        live_agent = entry.get("agent") if entry and isinstance(entry.get("agent"), dict) else None
        live_reason = entry.get("reason") if entry else None
        agent = None
        if live_agent and live_agent.get("provider") and live_reason in (None, "sin_id"):
            provider = live_agent["provider"]
            session = live_agent.get("session_id")
            cwd = live_agent.get("cwd")
            as_root = bool(live_agent.get("as_root"))
            agent = {"provider": provider, "display_name": DISPLAY_NAMES.get(provider, provider),
                     "session_id": session, "cwd": cwd, "as_root": as_root,
                     "source": live_agent.get("source") or "registro", "state": "activo",
                     "observed_at": cls.iso(live.get("checked_at")),
                     "resume": cls.resume(catalog, provider, session, cwd, as_root)}
        elif record.get("agent") in AGENTS:
            provider, session = record["agent"], record.get("sessionId")
            cwd = record.get("resumeCwd") or record.get("cwd") or workspace.get("cwd")
            as_root = record.get("asRoot")
            if not isinstance(as_root, bool):
                as_root = bool(host and host["user"] == "root")
            agent = {"provider": provider, "display_name": DISPLAY_NAMES.get(provider, provider),
                     "session_id": session, "cwd": cwd, "as_root": as_root, "source": "registro",
                     "state": "interrumpido" if record.get("interrupted") else "guardado",
                     "observed_at": cls.iso(record.get("agentObservedAt")),
                     "resume": cls.resume(catalog, provider, session, cwd, as_root)}
        if tmux is None:
            reason = "sin_tmux"
        elif entry is not None:
            live_reason = "sin_ia" if live_reason == "panel_muerto" else live_reason
            reason = live_reason if live_reason in LIVE_REASONS else None
        elif checked and not ok:
            reason = None if agent else "host_inaccesible"
        elif checked:
            reason = None if agent else "sin_ia"
        else:
            reason = None
        if reason is None and agent is not None and not agent["session_id"]:
            reason = "sin_id"
        return {"version": cls.VERSION, "workspace_id": workspace["id"], "terminal_id": record["id"],
                "checked_at": cls.iso(clock()),
                "workspace": {"name": workspace.get("name"), "kind": workspace.get("kind"),
                              "host": host, "host_label": host_label},
                "window": {"name": record.get("name")}, "tmux": tmux, "agent": agent, "reason": reason}

    @staticmethod
    def rows(details):
        """Filas del modal, en español y en el orden acordado: [(clave, etiqueta, valor)]."""
        workspace, tmux, agent, reason = details["workspace"], details["tmux"], details["agent"], details["reason"]
        ssh = workspace["kind"] == "ssh"
        rows = [("workspace", "Espacio de trabajo", workspace["name"] or ""),
                ("kind", "Tipo", ("VPS (%s)" % workspace["host_label"] if workspace["host_label"] else "VPS") if ssh else "Local"),
                ("window", "Ventana", details["window"]["name"] or "")]
        if tmux is None:
            rows.append(("tmux", "Sesión tmux", "Sin tmux: terminal directa sin sesión recuperable"))
        else:
            rows += [("socket", "Socket tmux", "Servidor tmux por defecto" if tmux["socket"] == "default" else tmux["socket"]),
                     ("session", "Sesión tmux", tmux["session"]),
                     ("tmux_id", "ID tmux", "%s · %s" % (tmux["session_id"], tmux["pane_id"])
                      if tmux["live"] and tmux["session_id"] else "No está en marcha ahora")]
        if reason == "identidad_ambigua":
            label = "Hay más de una IA en esta ventana"
        elif agent is None:
            label = "Sin IA detectada"
        elif not agent["session_id"]:
            label = agent["display_name"] + ": IA detectada, sin identificador todavía"
        elif reason == "sin_ia":
            label = agent["display_name"] + " (ahora no se detecta ninguna IA en marcha)"
        else:
            label = agent["display_name"]
        rows.append(("agent", "IA", label))
        if agent is not None:
            rows += [("state", "Estado", STATE_LABELS.get(agent["state"], agent["state"])),
                     ("session_id", "ID de conversación", agent["session_id"] or "Sin identificador todavía"),
                     ("cwd", "Carpeta", agent["cwd"] or "Desconocida")]
            if ssh:
                rows.append(("as_root", "Como root", "Sí" if agent["as_root"] else "No"))
            rows.append(("source", "Origen del dato", SOURCE_LABELS.get(agent["source"], agent["source"])))
            resume = agent["resume"]
            if resume:
                rows.append(("command", "Orden para reanudarla", resume["command"]))
                if not resume["no_prompt_verified"]:
                    rows.append(("no_prompt", "", "Sin modo sin preguntas verificado para esta IA"))
        return rows
