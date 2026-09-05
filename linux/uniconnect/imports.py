"""Side-effect-free previews for UniConnect documents and the recovered SSH map.

Previewing never resolves credentials or runs imported command strings. Connection
material is private to the pending import and is written only into the vault at
apply. Runtime launch policy reconstructs commands from agent/session metadata.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import time
import unicodedata
import uuid

from .state import StateStore
from .transport import SSHCommand, TransportError
from .vault import Envelope, Vault, VaultError, atomic_write


class ImportError(ValueError):
    """Unsupported or inconsistent import data, before any live mutation."""


@dataclass
class ImportPreview:
    """Sanitised proposed workspaces plus diagnostics; private credentials stay in RAM."""

    workspaces: list[dict]
    diagnostics: list[str]
    source_type: str
    archives: list[dict] = field(default_factory=list)
    _commands: dict[str, str] = field(default_factory=dict, repr=False)
    _vault: Vault | None = field(default=None, repr=False)
    _fingerprint: str = field(default="", repr=False)
    _snapshot: dict | None = field(default=None, repr=False)
    _source_fingerprint: str | None = field(default=None, repr=False)
    _base_state_fingerprint: str | None = field(default=None, repr=False)

    @property
    def window_count(self) -> int:
        return sum(len(item["windows"]) for item in self.workspaces)

    def select_workspace_ids(self, ids) -> "ImportPreview":
        """Copy selected complete workspaces without mutating this pending preview."""
        if self._fingerprint != Importer.fingerprint(self.workspaces):
            raise ImportError("Import preview changed; create a new preview")
        requested = set(ids)
        available = {item["id"] for item in self.workspaces}
        if not requested <= available:
            raise ImportError("Selection contains an unknown workspace")
        selected = copy.deepcopy([item for item in self.workspaces if item["id"] in requested])
        references = set()

        def visit(value):
            if isinstance(value, dict):
                for key, item in value.items():
                    if key in ("credentialId", "commandCredentialId") and item:
                        references.add(item)
                    visit(item)
            elif isinstance(value, list):
                for item in value:
                    visit(item)

        visit(selected)
        snapshot = copy.deepcopy(self._snapshot)
        if snapshot is not None:
            snapshot["workspaces"] = copy.deepcopy(selected)
            snapshot["closed"] = [item for item in snapshot.get("closed", [])
                                  if item.get("workspace", {}).get("id") in requested]
            visit(snapshot.get("closed", []))
            if snapshot.get("selectedWorkspaceId") not in requested:
                snapshot["selectedWorkspaceId"] = selected[0]["id"] if selected else None
        result = ImportPreview(selected, list(self.diagnostics), self.source_type,
                               copy.deepcopy(self.archives) if selected else [],
                               {key: value for key, value in self._commands.items() if key in references},
                               self._vault, _snapshot=snapshot)
        result._source_fingerprint = self._source_fingerprint
        result._base_state_fingerprint = self._base_state_fingerprint
        result._fingerprint = Importer.fingerprint(result.workspaces)
        return result

    def preflight(self, store: StateStore, remote_check=None) -> list[dict]:
        """Classify a preview without saving, attaching or creating remote sessions.

        ``remote_check(workspace, window, command) -> bool`` is an optional
        injected read-only tmux existence check. Commands never enter returned
        rows or diagnostics. The UI must run this on a worker when checking SSH.
        """
        if self._fingerprint != Importer.fingerprint(self.workspaces):
            raise ImportError("Import preview changed; create a new preview")
        baseline = StateStore._clean(copy.deepcopy(store.data))
        self._base_state_fingerprint = Importer.fingerprint(baseline)
        existing = {item["id"]: item for item in baseline["workspaces"]}
        agent_owners, ssh_owners = {}, {}

        def session_key(window):
            sid = window.get("sessionId")
            if not sid:
                return None
            try:
                sid = str(uuid.UUID(sid))
            except (ValueError, TypeError):
                pass
            return (window.get("agent"), sid)

        def command_for(workspace):
            identifier = workspace.get("credentialId")
            if identifier in self._commands:
                return self._commands[identifier]
            if identifier and self._vault is not None:
                return self._vault.get(identifier)
            return None

        def ssh_key(workspace, window, command):
            endpoint = SSHCommand.parse(command).endpoint_key(resolve=False) if command else (workspace.get("hostLabel"), workspace.get("credentialId"))
            return (endpoint, window.get("tmuxSocket", "uniconnect"), window.get("tmux"))

        for workspace in baseline["workspaces"]:
            try:
                command = command_for(workspace) if workspace["kind"] == "ssh" else None
            except VaultError:
                command = None
            for window in workspace["windows"]:
                owner = (workspace["id"], window["id"])
                key = session_key(window)
                if key:
                    agent_owners.setdefault(key, owner)
                if workspace["kind"] == "ssh":
                    ssh_owners.setdefault(ssh_key(workspace, window, command), owner)
        rows = []
        ignored = {"createdAt", "updatedAt", "lastActivityAt", "status", "restoreOnly", "sourceLine",
                   "firstSeenAt", "lastSeenAt", "connected", "autoResume", "sourceStatus"}

        def semantic(value):
            if isinstance(value, dict):
                return {key: semantic(item) for key, item in value.items() if key not in ignored}
            if isinstance(value, list):
                return [semantic(item) for item in value]
            return value

        for workspace in self.workspaces:
            old = existing.get(workspace["id"])
            errors = list(workspace.get("importDiagnostics", []))
            action = "create" if old is None else "unchanged"
            command = None
            if workspace.get("importRejected"):
                action = "rejected"
            if old is not None and (old.get("kind") != workspace.get("kind") or old.get("credentialId") != workspace.get("credentialId")):
                action = "conflict"
                errors.append("Existing workspace has a different connection or kind")
            if workspace["kind"] == "ssh":
                try:
                    command = command_for(workspace)
                    if command is None:
                        raise VaultError("missing")
                except VaultError:
                    action = "rejected"
                    errors.append("SSH credentials are missing or locked")
            window_rows = []
            old_windows = {item["id"]: item for item in old["windows"]} if old else {}
            for window in workspace["windows"]:
                previous = old_windows.get(window["id"])
                window_action = "create" if previous is None else ("unchanged" if semantic(previous) == semantic(window) else "update")
                notes = list(window.get("importDiagnostics", []))
                if window.get("importRejected"):
                    window_action = "rejected"
                owner = (workspace["id"], window["id"])
                key = session_key(window)
                if key and agent_owners.setdefault(key, owner) != owner:
                    notes.append("Another window owns this agent session; manual resume is required")
                    window_action = "conflict"
                checked = None
                if workspace["kind"] == "ssh" and command:
                    target = ssh_key(workspace, window, command)
                    if ssh_owners.setdefault(target, owner) != owner:
                        notes.append("Another window owns this SSH tmux target")
                        window_action = "conflict"
                    if remote_check is not None:
                        try:
                            checked = bool(remote_check(copy.deepcopy(workspace), copy.deepcopy(window), command))
                        except Exception:
                            checked = False
                        if not checked:
                            notes.append("The saved remote tmux session is unavailable")
                            window_action = "rejected"
                window_rows.append({"id": window["id"], "name": window["name"], "action": window_action,
                                    "sourceLine": window.get("sourceLine"), "diagnostics": notes,
                                    "remoteReady": checked})
            outcomes = {row["action"] for row in window_rows}
            if "rejected" in outcomes:
                action = "rejected"
            elif "conflict" in outcomes and action != "rejected":
                action = "conflict"
            elif action == "unchanged" and (outcomes & {"create", "update"} or semantic({k: v for k, v in old.items() if k != "windows"}) != semantic({k: v for k, v in workspace.items() if k != "windows"})):
                action = "update"
            rows.append({"id": workspace["id"], "name": workspace["name"], "action": action,
                         "sourceLine": workspace.get("sourceLine"), "diagnostics": errors, "windows": window_rows})
        return rows

    def apply(self, store: StateStore) -> list[dict]:
        if self._fingerprint != Importer.fingerprint(self.workspaces):
            raise ImportError("Import preview changed; create a new preview")
        if not self.workspaces:
            return []
        if any(item.get("importRejected") or any(window.get("importRejected") for window in item["windows"])
               for item in self.workspaces):
            raise ImportError("Rejected import declarations must be excluded before applying")
        if self._commands and self._vault is None:
            raise ImportError("SSH import requires a credential vault")
        if self._commands:
            self._vault._require_unlocked()
        # Validate all missing credential references before creating the checkpoint.
        for workspace in self.workspaces:
            reference = workspace.get("credentialId")
            existing = next((item for item in store.workspaces if item["id"] == workspace["id"]), None)
            if existing is not None and (existing.get("kind") != workspace.get("kind")
                                         or existing.get("credentialId") != reference):
                raise ImportError("Existing workspace uses a different immutable connection; edit it explicitly")
            if workspace["kind"] == "ssh" and not reference:
                raise ImportError("An SSH workspace is missing its connection")
            if reference and reference not in self._commands:
                if self._vault is None:
                    raise ImportError("This snapshot needs its original credential vault or a connection override")
                self._vault.get(reference)
        if store.vault is None and self._vault is not None:
            store.vault = self._vault
        with store.transaction("import", source_fingerprint=self._source_fingerprint,
                               plan_fingerprint=self._fingerprint) as transaction:
            if self._base_state_fingerprint is not None and self._base_state_fingerprint != Importer.fingerprint(StateStore._clean(store.data)):
                raise ImportError("Workspace state changed after import preflight; preview again")
            store.checkpoint("before-import")
            with transaction.step("vault"):
                for identifier, command in self._commands.items():
                    self._vault.put(command, identifier)
            with transaction.step("model"):
                return self._apply_model(store)

    def _apply_model(self, store: StateStore) -> list[dict]:
        original = copy.deepcopy(store.data)
        references = store._model_references()
        applied = []
        try:
            for proposed in copy.deepcopy(self.workspaces):
                existing = next((item for item in store.workspaces if item["id"] == proposed["id"]), None)
                if existing is None:
                    store.workspaces.append(proposed)
                    applied.append(proposed)
                    continue
                # Re-imports add missing windows and histories without retargeting live work.
                if existing.get("credentialId") != proposed.get("credentialId"):
                    raise ImportError("Existing workspace uses a different immutable connection; edit it explicitly")
                known = {window["id"]: window for window in existing["windows"]}
                for window in proposed["windows"]:
                    if window["id"] not in known:
                        existing["windows"].append(window)
                    else:
                        history = known[window["id"]].setdefault("history", [])
                        keys = {(item.get("agent"), item.get("sessionId")) for item in history}
                        history.extend(item for item in window.get("history", [])
                                       if (item.get("agent"), item.get("sessionId")) not in keys)
                        preserved_history = history
                        runtime = {key: known[window["id"]][key] for key in ("status", "restoreOnly", "connected")
                                   if key in known[window["id"]]}
                        known[window["id"]].update(window)
                        known[window["id"]].update(runtime)
                        known[window["id"]]["history"] = preserved_history
                existing.update({key: value for key, value in proposed.items() if key != "windows"})
                applied.append(existing)
            archives = store.data.setdefault("unassignedArchives", [])
            known_archives = {item.get("sessionId") for item in archives}
            archives.extend(copy.deepcopy(item) for item in self.archives if item.get("sessionId") not in known_archives)
            if self._snapshot is not None:
                source = self._snapshot
                for key, value in source.items():
                    if key not in ("workspaces", "closed", "version", "app", "savedAt", "recovery", "unassignedArchives", "selectedWorkspaceId"):
                        if key == "settings":
                            # Import missing preferences without overwriting current user choices.
                            for name, setting in value.items():
                                store.data.setdefault("settings", {}).setdefault(name, copy.deepcopy(setting))
                        else:
                            store.data.setdefault(key, copy.deepcopy(value))
                closed_ids = {item["id"] for item in store.closed}
                store.closed.extend(copy.deepcopy(item) for item in source.get("closed", []) if item["id"] not in closed_ids)
                if not original["workspaces"] and source.get("selectedWorkspaceId") in {item["id"] for item in store.workspaces}:
                    store.data["selectedWorkspaceId"] = source["selectedWorkspaceId"]
            if applied and not store.data.get("selectedWorkspaceId"):
                store.data["selectedWorkspaceId"] = applied[0]["id"]
            store.save()
        except Exception:
            store._restore_model(original, references)
            raise
        return applied


class Importer:
    """Normalize seed v1/v2, Linux state, macOS session snapshots and AES-GCM exports."""

    agents = {"codex", "claude", "agy", "grok", "shell", "custom"}

    def __init__(self, vault: Vault | None = None):
        self.vault = vault

    @staticmethod
    def fingerprint(workspaces: list[dict]) -> str:
        return hashlib.sha256(json.dumps(workspaces, sort_keys=True, ensure_ascii=False).encode()).hexdigest()

    @staticmethod
    def stable_id(value: str) -> str:
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "uniconnect-linux:" + value))

    @staticmethod
    def tmux_name(name: str, session_id: str) -> str:
        ascii_name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
        slug = re.sub(r"[^a-z0-9]+", "-", ascii_name.lower()).strip("-")[:28] or "window"
        return "uc-" + slug + "-" + session_id[:8].lower()

    @staticmethod
    def _text(value, maximum: int = 4096) -> str | None:
        if value is None:
            return None
        if not isinstance(value, str) or len(value) > maximum or any(ord(c) < 32 for c in value):
            raise ImportError("Import contains an invalid or oversized text field")
        return value

    @classmethod
    def _identity(cls, value, fallback: str) -> str:
        if value:
            try:
                return str(uuid.UUID(value))
            except (ValueError, TypeError, AttributeError):
                raise ImportError("Import contains an invalid stable UUID") from None
        return cls.stable_id(fallback)

    @classmethod
    def _agent(cls, value) -> str:
        value = {"antigravity": "agy", "gemini-antigravity": "agy", "gemini": "agy"}.get(value, value)
        if value is None:
            return "shell"
        if value not in cls.agents:
            raise ImportError("Import references an unsupported agent")
        return value

    @staticmethod
    def _connection_label(command: str) -> str:
        try:
            connection = SSHCommand.parse(command)
        except TransportError:
            raise ImportError("The SSH connection contains unsupported or unsafe options") from None
        username = None
        for index, option in enumerate(connection.options[:-1]):
            if option == "-l":
                username = connection.options[index + 1]
        return (username + "@" if username and "@" not in connection.destination else "") + connection.destination

    def preview(self, source, passphrase: str | None = None, default_connect: str | None = None) -> ImportPreview:
        source_path = None
        if isinstance(source, Path):
            source_path = source
            data = source.read_bytes()
        elif isinstance(source, str):
            if source.lstrip().startswith(("{", "[", "#")) or "\n" in source:
                data = source.encode()
            else:
                source_path = Path(source)
                data = source_path.read_bytes()
        elif isinstance(source, dict):
            data = None
            document = copy.deepcopy(source)
        else:
            data = source
        encrypted = False
        markdown = False
        diagnostics, archives = [], []
        if data is not None:
            if not isinstance(data, bytes) or len(data) > 32 * 1024 * 1024:
                raise ImportError("Import exceeds the supported size")
            if source_path is not None and source_path.suffix.lower() not in (".md", ".markdown", ".json", ".uc", ".uniconnect"):
                raise ImportError("Choose a CONNECT.md, JSON or encrypted UniConnect file")
            try:
                decoded = data.decode("utf-8-sig")
            except UnicodeError:
                raise ImportError("Import must be valid UTF-8 text") from None
            markdown = (source_path is not None and source_path.suffix.lower() in (".md", ".markdown")) or decoded.lstrip().startswith("#")
            if markdown:
                document, diagnostics = self._markdown(decoded)
            else:
                try:
                    document = json.loads(decoded)
                except ValueError:
                    raise ImportError("Import must contain JSON or a CONNECT Markdown document") from None
        if not isinstance(document, dict):
            raise ImportError("Import must contain a JSON object")
        if document.get("format") == Envelope.format:
            if passphrase is None:
                raise ImportError("A password is required for this encrypted export")
            try:
                document = json.loads(Envelope.open_with_passphrase(document, passphrase))
            except (ValueError, UnicodeError) as error:
                raise ImportError(str(error)) from None
            encrypted = True
        if document.get("schema_version") == "iberiavo-workspaces/v1":
            source_type = "iberiavo-workspaces/v1"
            raw_workspaces, archives = self._iberiavo(document)
        elif "workspaces" in document:
            version = document.get("version", 1)
            if type(version) is not int or not 1 <= version <= 2:
                raise ImportError("Unsupported workspace document version")
            source_type = "connect-markdown" if markdown else ("linux-state" if document.get("app") == "UniConnect Linux" else "uniconnect-document")
            raw_workspaces = document["workspaces"]
            archives = document.get("unassignedArchives", [])
        elif isinstance(document.get("windows"), list):
            source_type = "macos-session"
            raw_workspaces = self._macos_snapshot(document, diagnostics)
        else:
            raise ImportError("No supported workspace document was found")
        if not isinstance(raw_workspaces, list):
            raise ImportError("The workspaces field must be an array")
        commands, workspaces, identities = {}, [], set()
        for identifier, material in document.get("credentialArchive", {}).items():
            identifier = self._identity(identifier, "")
            if not isinstance(material, str) or not material.strip() or "\0" in material:
                raise ImportError("Invalid encrypted credential archive")
            commands[identifier] = material
        known_credentials = {}
        if self.vault is not None and not self.vault.locked:
            known_credentials = {value: key for key, value in self.vault._entries.items()}
        known_credentials.update({value: key for key, value in commands.items()})
        for raw in raw_workspaces:
            workspace = self._workspace(raw, default_connect, commands, known_credentials)
            if workspace["id"] in identities:
                raise ImportError("Import declares the same workspace identity twice")
            identities.add(workspace["id"])
            workspaces.append(workspace)
        if encrypted:
            source_type = "encrypted-" + source_type
        preview = ImportPreview(workspaces, diagnostics, source_type, StateStore._clean(archives), commands, self.vault)
        preview._source_fingerprint = hashlib.sha256(data if data is not None else json.dumps(document, sort_keys=True).encode()).hexdigest()
        snapshot = document.get("linuxState") or (document if source_type == "linux-state" else None)
        if snapshot is not None:
            if not isinstance(snapshot, dict):
                raise ImportError("Invalid embedded Linux state")
            preview._snapshot = StateStore._clean(copy.deepcopy(snapshot))
            preview._snapshot["workspaces"] = copy.deepcopy(workspaces)
        preview._fingerprint = self.fingerprint(workspaces)
        return preview

    def _workspace(self, raw: dict, default_connect, commands: dict, known_credentials: dict) -> dict:
        if not isinstance(raw, dict):
            raise ImportError("Each workspace must be an object")
        name = self._text(raw.get("name"), 512)
        if not name or not name.strip():
            raise ImportError("Every workspace needs a name")
        kind = raw.get("kind", "local")
        if kind not in ("local", "ssh"):
            raise ImportError("Workspace kind must be local or ssh")
        identifier = self._identity(raw.get("id"), f"workspace:{raw.get('group', '')}:{name}")
        cwd = self._text(raw.get("cwd")) or ("~" if kind == "local" else None)
        workspace = StateStore._clean(copy.deepcopy(raw))
        workspace.update({"id": identifier, "name": name, "kind": kind, "cwd": cwd,
                     "windows": [], "color": self._text(raw.get("color"), 64),
                     "group": self._text(raw.get("group"), 512), "isPinned": bool(raw.get("isPinned", False)),
                     "createdAt": raw.get("createdAt", time.time()), "restoreOnly": True})
        for key in ("layout", "selectedWindowId", "importIdentity", "tmuxReady", "lastActivityAt"):
            if key in raw:
                workspace[key] = StateStore._clean(raw[key])
        if kind == "ssh":
            command = default_connect or raw.get("connect")
            if command:
                try:
                    label = self._connection_label(command)
                except ImportError:
                    if not raw.get("sourceLine"):
                        raise
                    workspace["importRejected"] = True
                    workspace.setdefault("importDiagnostics", []).append("Unsafe SSH connection declaration")
                    command = None
            if command:
                # Random immutable IDs reveal no hash of the connection material.
                credential = known_credentials.get(command.strip())
                if credential is None:
                    credential = next((key for key, value in commands.items() if value == command.strip()), None)
                credential = credential or str(uuid.uuid4())
                commands[credential] = command.strip()
                workspace.update(credentialId=credential, hostLabel=label)
            else:
                workspace.update(credentialId=raw.get("credentialId"), hostLabel=self._text(raw.get("hostLabel"), 512))
        windows = raw.get("windows", [])
        if not isinstance(windows, list):
            raise ImportError("Workspace windows must be an array")
        seen = set()
        for index, window in enumerate(windows):
            try:
                normalized = self._window(window, workspace, index)
            except ImportError:
                if not raw.get("sourceLine"):
                    raise
                normalized = self._window({"name": window.get("name") or "Invalid window",
                                           "sourceLine": window.get("sourceLine", raw["sourceLine"]),
                                           "importRejected": True,
                                           "importDiagnostics": ["Invalid window declaration"]}, workspace, index)
            if normalized["id"] in seen:
                raise ImportError("A workspace contains duplicate window identities")
            seen.add(normalized["id"])
            workspace["windows"].append(normalized)
        return workspace

    def _window(self, raw: dict, workspace: dict, index: int) -> dict:
        if not isinstance(raw, dict):
            raise ImportError("Each window must be an object")
        local = raw.get("localWindow") or {}
        name = self._text(raw.get("name") or local.get("visibleName"), 512) or f"Terminal {index + 1}"
        history = []
        for record in raw.get("history", local.get("conversations", [])):
            session_id = self._text(record.get("sessionId") or record.get("sessionID"), 1024)
            if session_id:
                normalized_history = StateStore._clean(copy.deepcopy(record))
                normalized_history.update({"id": record.get("id") or self.stable_id("conversation:" + session_id),
                                "agent": self._agent(record.get("agent") or record.get("kind")),
                                "sessionId": session_id,
                                "firstSeenAt": record.get("firstSeenAt", time.time()),
                                "lastSeenAt": record.get("lastSeenAt", time.time())})
                history.append(normalized_history)
        selected = next((item for item in history if item["id"] == local.get("activeConversationID")), None)
        selected = selected or next((item for item in history if item["id"] == local.get("latestConversationID")), None)
        selected = selected or (history[-1] if history else {})
        session_id = self._text(raw.get("sessionId") or raw.get("codexSession") or raw.get("claudeSession") or selected.get("sessionId"), 1024)
        agent = self._agent(raw.get("agent") or ("codex" if raw.get("codexSession") else None)
                            or ("claude" if raw.get("claudeSession") else None) or selected.get("agent"))
        identifier = self._identity(raw.get("id") or local.get("id"), f"window:{workspace['id']}:{name}:{session_id or index}")
        cwd = self._text(raw.get("cwd") or local.get("workingDirectory") or workspace.get("cwd"))
        window = StateStore._clean(copy.deepcopy(raw))
        window.update({"id": identifier, "name": name, "kind": raw.get("kind", workspace["kind"]), "cwd": cwd,
                  "agent": agent, "sessionId": session_id, "history": history,
                  "isPinned": bool(raw.get("isPinned", False)), "restoreOnly": True,
                  "status": "disconnected" if workspace["kind"] == "ssh" else "stopped"})
        if session_id and (agent, session_id) not in {(h["agent"], h["sessionId"]) for h in history}:
            history.append({"id": self.stable_id("conversation:" + agent + ":" + session_id), "agent": agent,
                            "sessionId": session_id, "firstSeenAt": time.time(), "lastSeenAt": time.time()})
        if workspace["kind"] == "ssh":
            tmux = self._text(raw.get("tmux"), 256)
            if not tmux:
                tmux = self.tmux_name(name, session_id or identifier)
            if not re.fullmatch(r"[a-zA-Z0-9_-]{1,256}", tmux):
                raise ImportError("Invalid tmux session name")
            window.update(tmux=tmux, tmuxSocket=self._text(raw.get("tmuxSocket"), 80) or "uniconnect")
        for key in ("repo", "model", "effort", "paneId", "layout", "url", "task", "sourceStatus",
                    "sourceTty", "predecessorIds", "commandCredentialId", "runtimeState", "createdAt", "updatedAt"):
            if key in raw:
                window[key] = StateStore._clean(raw[key])
        return window

    def _iberiavo(self, document: dict) -> tuple[list[dict], list[dict]]:
        root = document["workspace"]
        group_name, cwd = root["name"], root["root"]
        target_model = root.get("model_migration", {}).get("target")
        effort = root.get("model_migration", {}).get("observed_effort")
        workspaces = []

        def convert(window: dict, session: dict, name: str | None = None) -> dict:
            agent = self._agent(session.get("engine", "codex"))
            sid = session.get("canonical_id") or session.get("id")
            return {"name": name or window["name"], "cwd": cwd, "repo": window.get("repo"),
                    "agent": agent, "sessionId": sid, "model": target_model if agent == "codex" else None,
                    "effort": effort if agent == "codex" else None,
                    "task": window.get("task"), "sourceStatus": session.get("status"),
                    "sourceTty": session.get("tty"), "predecessorIds": session.get("predecessor_ids", [])}

        for group in root["window_groups"]:
            windows = []
            for original in group["windows"]:
                session = original.get("session", {})
                windows.append(convert(original, session))
                for parallel in session.get("currently_open_parallel_sessions", []):
                    parallel = dict(parallel, engine=session.get("engine", "codex"), status="active")
                    name = original["name"] + " · " + parallel.get("scope", "parallel")
                    windows.append(convert(original, parallel, name))
            workspaces.append({"name": group["name"], "group": group_name, "kind": "ssh", "cwd": cwd, "windows": windows})
        for additional in document.get("additional_workspaces", []):
            window = convert(additional, additional["session"])
            window["cwd"] = additional.get("root", cwd)
            workspaces.append({"name": additional["name"], "group": group_name, "kind": "ssh",
                               "cwd": additional.get("root", cwd), "windows": [window]})
        archives = [{"agent": self._agent(item.get("engine")), "sessionId": item.get("id"),
                     "name": item.get("title", "Claude archive"), "status": item.get("status"),
                     "resumeProven": item.get("resume_proven", item.get("status") == "stored_not_running")}
                    for item in document.get("unassigned_claude_archives", [])]
        return workspaces, archives

    def _markdown(self, text: str) -> tuple[dict, list[str]]:
        """Parse human connection maps; command text is recognized, never executed."""
        workspaces, diagnostics = [], []
        current, section_kind, fence = None, None, None
        headers, pending_name = [], None

        def folded(value):
            return unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode().lower()

        def clean_cell(value):
            quoted = re.search(r"`([^`]+)`", value)
            return (quoted.group(1) if quoted else value.strip().strip("*")).strip().removesuffix("⚠️").strip()

        def issue(line, message, window=None):
            diagnostics.append(f"Line {line}: {message}")
            target = window if window is not None else current
            if target is not None:
                target["importRejected"] = True
                target.setdefault("importDiagnostics", []).append(message)

        def finish():
            nonlocal current, headers, pending_name
            if current is not None:
                if current["kind"] == "local" and not current.get("cwd"):
                    paths = [item["cwd"] for item in current["windows"] if item.get("cwd")]
                    if paths:
                        try:
                            current["cwd"] = os.path.commonpath(paths)
                        except ValueError:
                            issue(current["sourceLine"], "Local directories do not share a trusted root")
                if current["windows"] or current.get("connect") or current.get("importRejected"):
                    workspaces.append(current)
            current, headers, pending_name = None, [], None

        def absorb_command(raw, line):
            nonlocal pending_name
            command = raw.strip()
            if not command:
                return
            if command.startswith("#"):
                pending_name = command.lstrip("#").strip() or None
                return
            if command.startswith(("ssh ", "sshpass ", "/usr/bin/ssh ", "/usr/bin/sshpass ")):
                if current["kind"] == "local" and current.get("kindDeclared"):
                    issue(line, "SSH command conflicts with the LOCAL box type")
                    return
                current["kind"] = "ssh"
                try:
                    self._connection_label(command)
                except ImportError:
                    issue(line, "Unsafe SSH connection declaration")
                    return
                if current.get("connect") and current["connect"] != command:
                    issue(line, "A box declares multiple different SSH connections")
                else:
                    current["connect"] = command
                return
            # Recognise one documented cwd prefix; never execute imported chaining.
            cwd = current.get("cwd")
            if command.startswith("cd "):
                prefix, separator, rest = command.partition("&&")
                try:
                    parts = shlex.split(prefix)
                except ValueError:
                    issue(line, "Invalid directory declaration")
                    return
                if len(parts) != 2 or any(c in parts[1] for c in (";", "|", "`", "$", "\n")):
                    issue(line, "Unsafe directory declaration")
                    return
                cwd = os.path.expanduser(parts[1])
                if not separator:
                    current["cwd"] = cwd
                    return
                command = rest.strip()
            if any(token in command for token in (";", "&&", "||", "|", ">", "<", "`", "$(")):
                issue(line, "Shell execution is not allowed in a resume declaration")
                return
            try:
                words = shlex.split(command)
            except ValueError:
                issue(line, "Invalid resume declaration")
                return
            if not words:
                return
            executable = Path(words[0]).name
            if executable not in ("codex", "claude", "agy", "grok"):
                issue(line, "Unsupported command in a connection map")
                return
            sid, model, index = None, None, 1
            if executable == "codex":
                if index >= len(words) or words[index] != "resume":
                    issue(line, "Codex declaration must identify a resumable session")
                    return
                index += 1
            while index < len(words):
                token = words[index]
                if token in ("--resume", "--conversation", "-r") and executable != "codex":
                    if index + 1 < len(words):
                        sid = words[index + 1]
                        index += 2
                        continue
                if token in ("-C", "--cd", "-m", "--model") and index + 1 < len(words):
                    if token in ("-C", "--cd"):
                        cwd = os.path.expanduser(words[index + 1])
                    else:
                        model = words[index + 1]
                    index += 2
                    continue
                if token in ("--dangerously-skip-permissions", "--yolo", "--full-auto"):
                    # These flags do not become reconstructed Linux launch policy.
                    index += 1
                    continue
                if executable == "codex" and not token.startswith("-") and sid is None:
                    sid = token
                    index += 1
                    continue
                issue(line, "Unsupported resume option in a connection map")
                return
            if not sid or sid.startswith("-") or len(sid) > 1024:
                issue(line, "Resume declaration is missing its session identity")
                return
            match = next((item for item in current["windows"] if item.get("sessionId") == sid), None)
            match = match or next((item for item in current["windows"] if pending_name and item["name"] == pending_name), None)
            if match is None:
                match = {"name": pending_name or executable.title(), "sourceLine": line}
                current["windows"].append(match)
            match.update(agent=executable, sessionId=sid)
            if cwd:
                match["cwd"] = cwd
            if model:
                match["model"] = model
            pending_name = None

        for line_number, raw in enumerate(text.splitlines(), 1):
            line = raw.strip()
            if fence is not None:
                if line.startswith(fence):
                    fence = None
                elif current is not None:
                    absorb_command(raw, line_number)
                continue
            if line.startswith(("```", "~~~")):
                fence = line[:3]
                continue
            heading = re.match(r"^(#{1,6})(?:\s+|$)(.*)$", line)
            if heading:
                level, title = len(heading.group(1)), heading.group(2).strip()
                normalized = folded(title)
                detected = "ssh" if re.search(r"\bssh\b", normalized) else ("local" if re.search(r"\blocal(?:es|s)?\b", normalized) else None)
                if level == 1 or (level <= 2 and re.search(r"\b(cajas|boxes|workspaces)\b", normalized)):
                    finish()
                    section_kind = detected
                    continue
                if level <= 3 or current is None:
                    finish()
                    title = re.sub(r"^\d+(?:\.\d+)*[.)]?\s*[·:—-]?\s*", "", title)
                    title = re.sub(r"^(?:Caja|Box|Workspace)\s+", "", title, flags=re.IGNORECASE)
                    quoted = re.match(r'["“]([^"”]+)["”]', title)
                    if quoted:
                        title = quoted.group(1)
                    else:
                        title = re.split(r"\s+[—–]\s+|\s+-\s+(?=\d|tmux|LOCAL|SSH)", title, maxsplit=1)[0]
                        title = re.sub(r"\s*\((?:LOCAL|SSH)\)\s*$", "", title, flags=re.IGNORECASE)
                    current = {"name": title or "Unnamed workspace", "kind": detected or section_kind or "local",
                               "kindDeclared": bool(detected or section_kind), "sourceLine": line_number, "windows": []}
                    if not title:
                        issue(line_number, "Workspace heading is missing a name")
                continue
            if current is None:
                continue
            if line.startswith("|"):
                cells = [clean_cell(cell) for cell in re.split(r"(?<!\\)\|", line.strip("|"))]
                if cells and all(re.fullmatch(r"[-: ]+", cell) for cell in cells):
                    continue
                columns = []
                for cell in cells:
                    value = folded(cell)
                    if re.match(r"^tmux(?:\s|$)", value):
                        columns.append("tmux")
                    elif re.match(r"^(?:uuid|session|sesion)(?:\s|$)", value):
                        columns.append("sessionId")
                    elif any(term in value for term in ("ruta", "directory", "folder", "cwd", "path")):
                        columns.append("cwd")
                    elif value in ("ventana", "window", "nombre", "name"):
                        columns.append("name")
                    elif value in ("agent", "agente", "engine"):
                        columns.append("agent")
                    else:
                        columns.append(None)
                if "tmux" in columns or "sessionId" in columns:
                    headers = columns
                    continue
                if not headers or len(cells) != len(headers):
                    issue(line_number, "Malformed window table row")
                    continue
                values = {column: cell for column, cell in zip(headers, cells) if column and cell}
                values["sourceLine"] = line_number
                values.setdefault("name", values.get("tmux") or "Unnamed window")
                if values.get("cwd"):
                    values["cwd"] = os.path.expanduser(values["cwd"])
                if values.get("tmux"):
                    current["kind"] = "ssh"
                if values.get("sessionId"):
                    values.setdefault("agent", "claude")
                if not values.get("tmux") and not values.get("sessionId"):
                    issue(line_number, "Window declaration is missing its session identity", values)
                if values.get("tmux") and not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", values["tmux"]):
                    issue(line_number, "Window declares an invalid tmux name", values)
                    values.pop("tmux")
                current["windows"].append(values)
                continue
            explicit = re.match(r"(?:\*\*)?(?:type|tipo)(?:\*\*)?\s*:\s*(LOCAL|SSH)\b", line, re.IGNORECASE)
            if explicit:
                current["kind"] = explicit.group(1).lower()
                current["kindDeclared"] = True
                continue
            directory = re.match(r"(?:cwd|root|ruta|carpeta|folder)\s*:\s*(.+)$", line, re.IGNORECASE)
            if directory:
                current["cwd"] = os.path.expanduser(clean_cell(directory.group(1)))
                continue
            if raw.startswith(("    ", "\t")) or line.startswith(("ssh ", "sshpass ", "cd ", "codex ", "claude ", "agy ", "grok ")):
                absorb_command(line, line_number)
            elif "tmux" in folded(line):
                for name in re.findall(r"`([A-Za-z0-9_-]+)`", line):
                    current["windows"].append({"name": name, "tmux": name, "sourceLine": line_number})
                    current["kind"] = "ssh"
        if fence is not None and current is not None:
            issue(len(text.splitlines()), "Unclosed fenced command block")
        finish()
        if not workspaces:
            raise ImportError("The Markdown document does not contain a recognizable connection map")
        return {"version": 2, "workspaces": workspaces}, diagnostics

    def _macos_snapshot(self, document: dict, diagnostics: list[str]) -> list[dict]:
        result = []
        for native_window in document["windows"]:
            manager = native_window.get("tabManager", {})
            groups = {item["id"]: item.get("name") for item in manager.get("workspaceGroups", [])}
            for workspace in manager.get("workspaces", []):
                profile = workspace.get("uniConnect") or {}
                windows = []
                for panel in workspace.get("panels", []):
                    terminal = panel.get("terminal")
                    if terminal is None:
                        diagnostics.append("A nonterminal macOS panel needs manual recreation: " + str(panel.get("type", "unknown")))
                        continue
                    agent = terminal.get("agent") or {}
                    windows.append({"id": panel.get("id"), "name": panel.get("customTitle") or panel.get("title"),
                                    "cwd": terminal.get("workingDirectory") or panel.get("directory"),
                                    "tmux": terminal.get("uniConnectTmuxSession"),
                                    "claudeSession": terminal.get("uniConnectClaudeSession"),
                                    "localWindow": terminal.get("uniConnectLocalWindow"),
                                    "sessionId": agent.get("sessionId"), "agent": agent.get("agent") or agent.get("kind"),
                                    "isPinned": panel.get("isPinned", False)})
                result.append({"id": workspace.get("workspaceId") or profile.get("importIdentity"),
                               "name": workspace.get("customTitle") or workspace.get("processTitle") or "Workspace",
                               "kind": profile.get("kind", "local"), "cwd": profile.get("localRoot") or workspace.get("currentDirectory"),
                               "credentialId": profile.get("credentialId"), "hostLabel": profile.get("hostLabel"),
                               "color": workspace.get("customColor"), "group": groups.get(workspace.get("groupId")),
                               "isPinned": workspace.get("isPinned", False), "windows": windows,
                               "layout": workspace.get("layout"), "selectedWindowId": workspace.get("focusedPanelId"),
                               "nativeSnapshot": StateStore._clean(copy.deepcopy(workspace))})
        return result

    def export(self, store: StateStore, path: str | Path, passphrase: str) -> Path:
        """Write a password-protected transport document using the macOS envelope."""
        workspaces = copy.deepcopy(store.workspaces)
        for workspace in workspaces:
            if workspace["kind"] == "ssh":
                if self.vault is None:
                    raise ImportError("Encrypted export requires the credential vault")
                workspace["connect"] = self.vault.get(workspace["credentialId"])
            for window in workspace["windows"]:
                if workspace["kind"] == "local":
                    conversations = [{"id": item.get("id") or self.stable_id(item["sessionId"]),
                                      "kind": "antigravity" if item["agent"] == "agy" else item["agent"],
                                      "sessionID": item["sessionId"], "firstSeenAt": item.get("firstSeenAt", time.time())}
                                     for item in window.get("history", []) if item["agent"] != "shell"]
                    latest = next((item["id"] for item in conversations if item["sessionID"] == window.get("sessionId")), None)
                    window["localWindow"] = {"version": 2, "id": window["id"], "visibleName": window["name"],
                                             "boxRoot": workspace.get("cwd") or "~", "workingDirectory": window.get("cwd") or workspace.get("cwd") or "~",
                                             "runtimeState": "shell", "conversations": conversations, "latestConversationID": latest,
                                             "createdAt": window.get("createdAt", time.time()), "updatedAt": time.time()}
        document = {"version": 2, "app": "UniConnect", "savedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "workspaces": workspaces, "unassignedArchives": store.data.get("unassignedArchives", []),
                    "linuxState": StateStore._clean(copy.deepcopy(store.data))}
        references = store._credential_ids(store.data)
        if references:
            if self.vault is None:
                raise ImportError("Encrypted export requires the credential vault")
            document["credentialArchive"] = {identifier: self.vault.get(identifier) for identifier in references}
        path = Path(path)
        atomic_write(path, Envelope.seal_with_passphrase(json.dumps(document, ensure_ascii=False).encode(), passphrase))
        return path
