"""El árbol de conexiones en disco (agent-tree-v1, 08-11): `agent-tree.json` en cada guardado.

Es la forma de `contracts/agent-tree-v1/arbol-ejemplo.json`, construida solo con lo que ya
está en `state.json`: espacios, ventanas y, por ventana, local o SSH, servidor, tmux, IA,
conversación, historial y las opciones de lanzamiento permitidas. Sin secretos: ni
credenciales, ni argv crudo, ni entorno salvo `IS_SANDBOX`. Lo pueden leer Dani, una IA o
`recovery.py` sin RPC. Lo vivo (`$N`, `%N`, si el panel está vivo) no se guarda: va a `null`.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
import re
import socket

AGENTS = ("claude", "codex", "agy", "grok")
SOURCES = ("ficha", "rollout", "argv", "hook", "manifiesto", "registro")
HOST_LABEL = re.compile(r"^(?P<user>[^@\s]+)@(?P<hostname>[^:\s]+):(?P<port>\d{1,5})$")


def iso(value):
    """Época en segundos → ISO 8601 UTC, o None."""
    if not isinstance(value, (int, float)) or value <= 0:
        return None
    return datetime.fromtimestamp(value, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def host(label):
    match = HOST_LABEL.match(label or "")
    if not match:
        return None
    return {"user": match["user"], "hostname": match["hostname"], "port": int(match["port"])}


def launch(record):
    """Las opciones de lanzamiento guardadas, en la forma del contrato.

    En `state.json` van como ``launchOptions = {options, isSandbox, source, capturedAt}``:
    `StateStore.forbidden` borra a cualquier profundidad las claves ``arguments`` y
    ``environment`` (las de un argv o un entorno crudos), así que el contrato se arma aquí.
    """
    value = record.get("launchOptions")
    if not isinstance(value, dict) or not isinstance(value.get("options"), list):
        return None
    result = {"arguments": [item for item in value["options"] if isinstance(item, str)]}
    if value.get("isSandbox") is True:
        result["environment"] = {"IS_SANDBOX": "1"}
    result["source"] = value.get("source") if value.get("source") in ("argv", "rollout", "policy") else "argv"
    result["captured_at"] = iso(value.get("capturedAt"))
    return result


def agent(record):
    provider, session = record.get("agent"), record.get("sessionId")
    if provider == "antigravity":
        provider = "agy"
    if provider not in AGENTS or not isinstance(session, str) or not session:
        return None
    return {
        "provider": provider,
        "session_id": session,
        "cwd": record.get("resumeCwd") or record.get("cwd"),
        "as_root": bool(record.get("asRoot")),
        "source": record.get("agentSource") if record.get("agentSource") in SOURCES else "registro",
        # Lo guardado no está confirmado ahora mismo: «interrumpido» o «guardado», nunca «activo».
        "state": "interrumpido" if record.get("interrupted") else "guardado",
        "observed_at": iso(record.get("agentObservedAt")),
        "history": [{"provider": "agy" if item.get("agent") == "antigravity" else item.get("agent"),
                     "session_id": item.get("sessionId"), "cwd": item.get("cwd"),
                     "first_seen_at": iso(item.get("firstSeenAt")), "last_seen_at": iso(item.get("lastSeenAt"))}
                    for item in record.get("history", []) if isinstance(item, dict)],
        "launch": launch(record),
    }


def build(data, *, machine_id=None, now=None):
    """Árbol del contrato a partir del estado ya limpio de `StateStore` (sin secretos)."""
    workspaces = []
    for workspace in data.get("workspaces", []):
        kind = "ssh" if workspace.get("kind") == "ssh" else "local"
        label = workspace.get("hostLabel") if kind == "ssh" else None
        windows = []
        for record in workspace.get("windows", []):
            windows.append({
                "id": record.get("id"),
                "name": record.get("name"),
                "kind": kind,
                "host_label": label,
                "state": record.get("runtimeState") or ("agent" if record.get("sessionId") else "shell"),
                "tmux": ({"socket": record.get("tmuxSocket") or ("uniconnect" if kind == "ssh" else "uniconnect-local"),
                          "session": record["tmux"], "session_id": None, "pane_id": None, "live": None}
                         if record.get("tmux") else None),
                "agent": agent(record),
            })
        workspaces.append({"id": workspace.get("id"), "name": workspace.get("name"), "kind": kind,
                           "host": host(label), "host_label": label, "windows": windows})
    return {"version": 1, "machine_id": machine_id or socket.gethostname(), "platform": "linux",
            "checked_at": iso(now), "workspaces": workspaces}


def encode(document):
    return (json.dumps(document, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode()
