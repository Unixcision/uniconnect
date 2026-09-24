"""«Detalles» de una ventana (window_details.v1): el mismo JSON para el modal, el móvil y la CLI.

Solo lectura: combina lo guardado con una lectura viva de la sonda y deriva la orden para
reanudar la IA con la política sin preguntas del catálogo compartido. Nunca incluye la
orden de conexión, contraseñas ni credentialId. Reglas, precedencias y textos literales:
contracts/window-details-v1/LEEME.md (y filas.json).
"""

import ast
import datetime
import re

from .agent_tree import AgentTree
from .resume_catalog import AgentResumeCatalog

AGENTS = ("claude", "codex", "agy", "grok")
LIVE_REASONS = ("sin_ia", "identidad_ambigua", "sin_id")
SOURCE_LABELS = {"ficha": "Ficha de sesión de Claude", "rollout": "Registro abierto de Codex",
                 "argv": "Línea de órdenes del proceso (puede estar desfasada)", "hook": "Aviso del propio agente",
                 "manifiesto": "Supervisor del servidor", "registro": "Guardado en UniConnect"}
TITLE = "Detalles de la ventana"
CHECKING = "Comprobando…"
UNREACHABLE = "No se pudo comprobar el servidor; se muestra lo guardado"
UNREACHABLE_LOCAL = "No se pudo comprobar tmux en este equipo; se muestra lo guardado"
UNVERIFIED = "Sin modo sin preguntas verificado para esta IA"
EMPTY = "—"


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
    def endpoint_label(user, hostname, port):
        """``usuario@host:puerto`` (IPv6 entre corchetes, :22 si falta; sin usuario, ``host:puerto``)."""
        host = "[%s]" % hostname if ":" in hostname else hostname
        return "%s%s:%s" % (user + "@" if user else "", host, port or 22)

    @classmethod
    def host_label(cls, value):
        """La etiqueta guardada del perfil, normalizada a ``usuario@host:puerto``.

        Acepta la forma antigua ``str(tupla)`` y etiquetas sin puerto (``:22``).
        """
        if not isinstance(value, str) or not value.strip():
            return None
        value = value.strip()
        if value.startswith("("):
            try:
                parts = ast.literal_eval(value)
            except (ValueError, SyntaxError):
                return value
            if isinstance(parts, tuple) and len(parts) == 3 and all(isinstance(part, str) for part in parts):
                return cls.endpoint_label(*parts)
            return value
        user, at, rest = value.rpartition("@")
        bracketed = re.fullmatch(r"\[([^\]]+)\](?::(\d+))?", rest)
        if bracketed:
            host, port = bracketed.group(1), bracketed.group(2)
        elif rest.count(":") == 1 and rest.rsplit(":", 1)[1].isdigit():
            host, port = rest.rsplit(":", 1)
        else:
            host, port = rest, None  # Sin puerto (o IPv6 sin corchetes): el de SSH.
        if not host:
            return value
        return cls.endpoint_label(user if at else "", host, port)

    @classmethod
    def host(cls, workspace, endpoint=None):
        """(host, host_label). ``endpoint``: (usuario, host, puerto) del destino ya resuelto (ssh -G)."""
        if workspace.get("kind") != "ssh":
            return None, None
        if endpoint is not None:
            user, hostname, port = endpoint
            return ({"user": user, "hostname": hostname, "port": int(port) if str(port).isdigit() else port},
                    cls.endpoint_label(user, hostname, port))
        # Bóveda cerrada: sin destino verificado, solo la etiqueta del perfil.
        return None, cls.host_label(workspace.get("hostLabel"))

    @staticmethod
    def display_name(catalog, provider):
        """``displayName`` del catálogo compartido; sin él (o sin catálogo), el id del proveedor."""
        return catalog.display_name(provider) if catalog is not None else provider

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

    @staticmethod
    def saved_conversation(workspace, record):
        """La última IA guardada de la ventana, aunque ahora esté en un shell (contrato, «agent» 2).

        La conversación activa guardada; si no tiene id, la más reciente del historial; y si
        tampoco hay, la IA guardada sin id. None si la ventana nunca tuvo IA.
        """
        folder = record.get("resumeCwd") or record.get("cwd") or workspace.get("cwd")
        if record.get("agent") in AGENTS and record.get("sessionId"):
            return {"provider": record["agent"], "session_id": record["sessionId"], "cwd": folder,
                    "observed": record.get("agentObservedAt"), "interrupted": bool(record.get("interrupted"))}
        history = [item for item in record.get("history", []) if isinstance(item, dict)
                   and item.get("agent") in AGENTS and item.get("sessionId")]
        if history:
            item = max(history, key=lambda entry: entry.get("lastSeenAt") or 0)
            return {"provider": item["agent"], "session_id": item["sessionId"], "cwd": item.get("cwd") or folder,
                    "observed": item.get("lastSeenAt"), "interrupted": False}
        if record.get("agent") in AGENTS:
            return {"provider": record["agent"], "session_id": None, "cwd": folder,
                    "observed": record.get("agentObservedAt"), "interrupted": bool(record.get("interrupted"))}
        return None

    @staticmethod
    def root_by_destination(host, host_label):
        """Sin dato guardado: el usuario del destino es root (el de ``host`` o, sin él, el de la etiqueta)."""
        if host is not None:
            return host.get("user") == "root"
        return bool(host_label) and "@" in host_label and host_label.rpartition("@")[0] == "root"

    @classmethod
    def snapshot(cls, workspace, record, live, catalog, clock, *, endpoint=None):
        """JSON exacto de contracts/window-details-v1 para una ventana.

        ``live``: None (sin comprobar todavía) o {"ok", "checked_at", "session", "error"}.
        """
        host, host_label = cls.host(workspace, endpoint)
        checked = live is not None
        ok = bool(live and live.get("ok"))
        entry = live.get("session") if ok else None
        if entry is not None and entry.get("live", True) is False:
            entry = None  # Una entrada sintetizada que la sonda no vio.
        tmux = None
        if record.get("tmux"):
            tmux = {"socket": AgentTree.socket_of(workspace, record), "session": record["tmux"],
                    "session_id": entry.get("session_id") if entry else None,
                    "pane_id": entry.get("pane_id") if entry else None, "live": entry is not None}
        live_agent = entry.get("agent") if entry and isinstance(entry.get("agent"), dict) else None
        live_reason = entry.get("reason") if entry else None
        agent = None
        if live_agent and live_agent.get("provider") and live_reason in (None, "sin_id"):
            # 1. La IA en marcha que vio la comprobación de ahora, con o sin id.
            provider = live_agent["provider"]
            session = live_agent.get("session_id") or None
            cwd = live_agent.get("cwd")
            as_root = bool(live_agent.get("as_root"))
            agent = {"provider": provider, "display_name": cls.display_name(catalog, provider),
                     "session_id": session, "cwd": cwd, "as_root": as_root,
                     "source": live_agent.get("source") if session else None, "state": "activo",
                     "observed_at": cls.iso(live.get("checked_at")),
                     "resume": cls.resume(catalog, provider, session, cwd, as_root)}
        else:
            # 2. La última IA guardada, aunque la ventana esté ahora en un shell.
            saved = cls.saved_conversation(workspace, record)
            if saved is not None:
                as_root = record.get("asRoot")
                if not isinstance(as_root, bool):
                    as_root = workspace.get("kind") == "ssh" and cls.root_by_destination(host, host_label)
                provider, session, cwd = saved["provider"], saved["session_id"], saved["cwd"]
                agent = {"provider": provider, "display_name": cls.display_name(catalog, provider),
                         "session_id": session, "cwd": cwd, "as_root": as_root, "source": "registro",
                         "state": "interrumpido" if saved["interrupted"] else "guardado",
                         "observed_at": cls.iso(saved["observed"]),
                         "resume": cls.resume(catalog, provider, session, cwd, as_root)}
        if tmux is None:
            reason = "sin_tmux"
        elif checked and not ok:
            reason = "host_inaccesible"  # Haya o no algo guardado; la bóveda cerrada también.
        elif entry is not None:
            shown = "sin_ia" if live_reason == "panel_muerto" else live_reason
            reason = shown if shown in LIVE_REASONS else None
        else:
            reason = None  # Comprobación bien y sesión parada (o todavía sin comprobar).
        return {"version": cls.VERSION, "workspace_id": workspace["id"], "terminal_id": record["id"],
                "checked_at": cls.iso(clock()),
                "workspace": {"name": workspace.get("name"), "kind": workspace.get("kind"),
                              "host": host, "host_label": host_label},
                "window": {"name": record.get("name")}, "tmux": tmux, "agent": agent, "reason": reason}

    @classmethod
    def gather(cls, workspace, record, *, connection, transport, catalog, clock, probe=None):
        """Fuera del hilo GTK: resuelve el destino (ssh -G) y lee la sonda de esa sesión (≤ 8 s).

        ``connection``: SSHCommand de la caja, o None (local o bóveda cerrada). ``transport``:
        el del grupo, o None si no se puede abrir sin preguntar. Nunca falla por la sonda:
        si no se pudo comprobar, responde con lo guardado y ``host_inaccesible``.
        """
        probe = probe or AgentTree.probe
        endpoint = None
        if connection is not None:
            try:
                endpoint = connection.endpoint_key()
            except Exception:
                endpoint = None
        live = None
        if record.get("tmux"):
            live = {"ok": False, "error": "host_inaccesible", "checked_at": None, "session": None}
            if transport is not None:
                try:
                    result = probe(transport, AgentTree.socket_of(workspace, record), [record["tmux"]], timeout=8)
                    if not result.get("error"):
                        entry = next((item for item in result["sessions"] if item.get("name") == record["tmux"]), None)
                        live = {"ok": True, "error": None, "checked_at": result.get("checked_at"), "session": entry}
                except Exception:
                    pass  # Nunca un error por la sonda: se responde con lo guardado.
        return cls.snapshot(workspace, record, live, catalog, clock, endpoint=endpoint)

    @staticmethod
    def text(value):
        return value if isinstance(value, str) and value else EMPTY

    @classmethod
    def rows(cls, details):
        """Filas del modal, literales de filas.json y en su orden: [(clave, etiqueta, valor)]."""
        workspace, tmux, agent, reason = details["workspace"], details["tmux"], details["agent"], details["reason"]
        ssh = workspace["kind"] == "ssh"
        rows = [("workspace", "Espacio de trabajo", cls.text(workspace.get("name"))),
                ("kind", "Tipo", ("VPS (%s)" % workspace["host_label"] if workspace.get("host_label") else "VPS")
                 if ssh else "Local"),
                ("window", "Ventana", cls.text(details["window"].get("name")))]
        if tmux is None:
            rows.append(("tmux", "Sesión tmux", "Sin tmux: terminal directa sin sesión recuperable"))
        else:
            if tmux["live"] and tmux["session_id"]:
                ident = tmux["session_id"] + (" · " + tmux["pane_id"] if tmux["pane_id"] else "")
            elif reason == "host_inaccesible":
                ident = "Sin comprobar"
            else:
                ident = "No está en marcha ahora"
            rows += [("socket", "Socket tmux", "Servidor tmux por defecto" if tmux["socket"] == "default" else tmux["socket"]),
                     ("session", "Sesión tmux", tmux["session"]),
                     ("tmux_id", "ID tmux", ident)]
        if reason == "identidad_ambigua":
            label = "Hay más de una IA en esta ventana"
        elif agent is None:
            label = "Sin IA guardada" if reason == "host_inaccesible" else "Sin IA detectada"
        elif not agent["session_id"]:
            label = agent["display_name"] + (": IA detectada, sin identificador todavía" if agent["state"] == "activo"
                                             else ": sin identificador guardado")
        else:
            label = agent["display_name"]
        rows.append(("agent", "IA", label))
        if agent is not None:
            state = agent["state"]
            if state == "activo":
                shown = "En marcha"
            elif state == "interrumpido":
                shown = "Interrumpida: se reanudará al abrir"
            elif state == "guardado":
                shown = ("Guardada; ahora no hay ninguna IA en marcha" if reason == "sin_ia"
                         else "Guardada (no comprobada ahora)")
            else:
                shown = state  # Un estado que no se conoce se enseña tal cual.
            rows += [("state", "Estado", shown),
                     ("session_id", "ID de conversación", cls.text(agent["session_id"])),
                     ("cwd", "Carpeta", cls.text(agent["cwd"]))]
            if ssh:
                rows.append(("as_root", "Como root", "Sí" if agent["as_root"] else "No"))
            source = agent["source"]
            rows.append(("source", "Origen del dato", SOURCE_LABELS.get(source, source) if source else EMPTY))
            if agent["resume"]:
                rows.append(("command", "Orden para reanudarla", agent["resume"]["command"]))
        return rows

    @staticmethod
    def warning(details):
        """Aviso encima de las filas cuando la comprobación falló (SSH o este equipo), o None."""
        if details["reason"] != "host_inaccesible":
            return None
        return UNREACHABLE if details["workspace"]["kind"] == "ssh" else UNREACHABLE_LOCAL

    @staticmethod
    def command_note(details):
        """Nota debajo de la orden si la IA no tiene modo sin preguntas verificado (grok), o None."""
        agent = details["agent"]
        resume = agent["resume"] if agent else None
        return UNVERIFIED if resume and not resume["no_prompt_verified"] else None
