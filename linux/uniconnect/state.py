"""Durable, secret-free Linux workspace state and paired recovery checkpoints."""

from __future__ import annotations

import copy
import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import time
import uuid

from .vault import (Vault, VaultError, VaultLocked, atomic_write, default_root, private_lock,
                    private_read, storage_lease, transaction_writer_active)


class StateError(ValueError):
    """A state change cannot be committed without losing durable information."""


class PersistentTransaction:
    """A journaled mutation scope; runtime callers may raise before commit on readiness failure."""

    def __init__(self, store, journal):
        self.store = store
        self.journal = journal

    @contextmanager
    def step(self, name: str):
        """Record a non-secret step before and after its mutation."""
        if not re.fullmatch(r"[a-z0-9:_-]{1,80}", name):
            raise StateError("Transaction step must be a stable non-secret identifier")
        self.mark(name, "before")
        yield
        self.mark(name, "after")

    def mark(self, name: str, phase: str) -> None:
        self.journal["phase"] = "mutating"
        self.journal.setdefault("events", []).append({"step": name, "phase": phase, "at": self.store.clock()})
        if len(self.journal["events"]) > 4096:
            raise StateError("Workspace transaction exceeds its journal limit")
        self.store._write_journal(self.journal)
        self.store._failpoint(name + ":" + phase)


class StateStore:
    """Single application owner's snapshot; callers mutate data then call save.

    An optional vault participates in backups. IDs never resolve to changed
    credentials: vault revisions are immutable and old revisions are retained.
    Backups commit the encrypted companion first and JSON last as commit marker.
    """

    forbidden = {"connect", "command", "sshcommand", "ssh_command", "password", "passphrase",
                 "argv", "arguments", "environment", "env", "privatekey", "private_key", "resum_command",
                 "resume_command", "resume_after_exit", "resumetemplate", "resume_template",
                 "tmuxstartcommand", "launchcommand", "launch_command", "shellcommand", "connectcommand"}

    def __init__(self, root: str | Path | None = None, vault: Vault | None = None, clock=time.time,
                 failpoint=None):
        self.root = Path(root) if root is not None else default_root()
        self.path = self.root / "state.json"
        self.backup_dir = self.root / "backups"
        self.transaction_dir = self.root / "transactions"
        self.journal_path = self.transaction_dir / "pending.json"
        self.vault = vault
        self.clock = clock
        self._failpoint = failpoint or (lambda stage: None)
        self._active_transaction = None
        self.last_recovery: str | None = None
        self.data = self.empty()
        self.last_backup_error: str | None = None
        self._disk_revision: str | None = None
        self.load()

    @staticmethod
    def empty() -> dict:
        return {"version": 1, "app": "UniConnect Linux", "workspaces": [], "closed": [],
                "settings": {}, "selectedWorkspaceId": None, "unassignedArchives": []}

    @property
    def workspaces(self) -> list[dict]:
        return self.data["workspaces"]

    @property
    def closed(self) -> list[dict]:
        return self.data["closed"]

    @classmethod
    def _clean(cls, item):
        if isinstance(item, dict):
            return {key: cls._clean(value) for key, value in item.items()
                    if isinstance(key, str) and key.lower() not in cls.forbidden}
        if isinstance(item, list):
            return [cls._clean(value) for value in item]
        if item is None or isinstance(item, (str, int, float, bool)):
            return item
        raise StateError("State contains a non-JSON value")

    @staticmethod
    def _validate(data: dict) -> None:
        if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("workspaces"), list):
            raise StateError("Unsupported Linux workspace snapshot")
        seen_workspaces, seen_windows = set(), set()
        for workspace in data["workspaces"]:
            if not isinstance(workspace, dict) or workspace.get("kind") not in ("local", "ssh"):
                raise StateError("Invalid workspace kind")
            wid = workspace.get("id")
            if not isinstance(wid, str) or not wid or wid in seen_workspaces:
                raise StateError("Workspace identities must be unique")
            seen_workspaces.add(wid)
            if not isinstance(workspace.get("name"), str) or not isinstance(workspace.get("windows"), list):
                raise StateError("Invalid workspace metadata")
            for window in workspace["windows"]:
                identifier = window.get("id") if isinstance(window, dict) else None
                if not isinstance(identifier, str) or not identifier or identifier in seen_windows:
                    raise StateError("Window identities must be unique")
                seen_windows.add(identifier)
        if not isinstance(data.get("closed", []), list) or not isinstance(data.get("settings", {}), dict):
            raise StateError("Invalid closed-window history or preferences")

    def load(self) -> dict:
        with storage_lease(self.root):
            if self._active_transaction is not None:
                raise StateError("Cannot reload state during an active workspace transaction")
            if self.journal_path.exists():
                if self.recover_pending_transaction() == "rolled-back":
                    return self.data
            return self._load_current()

    def _load_current(self) -> dict:
        if not self.path.exists():
            self.data = self.empty()
            self._disk_revision = None
            return self.data
        try:
            raw = private_read(self.path)
            data = json.loads(raw)
            self._validate(data)
            data.setdefault("closed", [])
            data.setdefault("settings", {})
            data.setdefault("unassignedArchives", [])
            self.data = self._clean(data)
            self._disk_revision = hashlib.sha256(raw).hexdigest()
            return self.data
        except (ValueError, OSError) as error:
            raise StateError("Workspace state could not be read; the original file was preserved") from error

    def save(self, scheduled: bool = True) -> None:
        with storage_lease(self.root):
            self._save_current(scheduled)

    def _save_current(self, scheduled: bool) -> None:
        clean = self._clean(self.data)
        self._validate(clean)
        clean["savedAt"] = self.clock()
        encoded = json.dumps(clean, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False).encode()
        with storage_lease(self.root), private_lock(self.root / ".state.lock"):
            if self.journal_path.exists() and self._active_transaction is None:
                raise StateError("A pending workspace transaction must be recovered before saving")
            if self.path.exists():
                revision = hashlib.sha256(private_read(self.path)).hexdigest()
                if revision != self._disk_revision:
                    raise StateError("Workspace state changed in another process; reload before saving")
            elif self._disk_revision is not None:
                raise StateError("Workspace state disappeared; reload before saving")
            atomic_write(self.path, encoded)
            self._disk_revision = hashlib.sha256(encoded).hexdigest()
        # UI action closures retain workspace/window dictionaries between saves.
        # Keep their identity stable; only the on-disk projection is reconstructed.
        self.data["savedAt"] = clean["savedAt"]
        if scheduled and self._active_transaction is None:
            try:
                self.checkpoint("scheduled")
                self.last_backup_error = None
            except (VaultError, StateError, OSError):
                self.last_backup_error = "Recovery checkpoint unavailable; unlock the vault and persist again"

    def _model_references(self) -> dict:
        references = {}

        def collect(value, path=()):
            if isinstance(value, dict):
                references[path] = value
                for name, item in value.items():
                    collect(item, path + (name,))
            elif isinstance(value, list):
                references[path] = value
                for index, item in enumerate(value):
                    marker = ("id", item["id"]) if isinstance(item, dict) and isinstance(item.get("id"), str) else index
                    collect(item, path + (marker,))

        collect(self.data)
        return references

    def _restore_model(self, snapshot: dict, references: dict | None = None) -> None:
        """Reconcile in place so terminals keep their original workspace/window objects."""
        references = references or self._model_references()

        def reconcile(current, saved, path=()):
            if isinstance(saved, dict):
                target = references.get(path, current)
                if not isinstance(target, dict):
                    target = {}
                for key in set(target) - set(saved):
                    del target[key]
                for key, value in saved.items():
                    target[key] = reconcile(target.get(key), value, path + (key,))
                return target
            if isinstance(saved, list):
                target = references.get(path, current)
                target = target if isinstance(target, list) else []
                old = list(target)
                values = []
                for index, value in enumerate(saved):
                    marker = ("id", value["id"]) if isinstance(value, dict) and isinstance(value.get("id"), str) else index
                    values.append(reconcile(old[index] if index < len(old) else None, value, path + (marker,)))
                target[:] = values
                return target
            return copy.deepcopy(saved)

        reconcile(self.data, snapshot)

    def mutate(self, callback, scheduled: bool = True):
        """Apply a model edit and save; failures restore original object identities."""
        with storage_lease(self.root):
            snapshot, references = copy.deepcopy(self.data), self._model_references()
            try:
                result = callback(self.data)
                self.save(scheduled=scheduled)
                return result
            except BaseException:
                self._restore_model(snapshot, references)
                raise

    def _transaction_vault(self) -> Vault:
        if self.vault is None:
            raise VaultLocked("An encrypted workspace transaction requires its credential vault")
        if self.vault.locked and self.vault.mode == "systemd-creds":
            self.vault.unlock()
        self.vault._require_unlocked()
        return self.vault

    def _write_journal(self, journal: dict) -> None:
        atomic_write(self.journal_path, json.dumps(journal, sort_keys=True, indent=2).encode())

    def _remove_private_file(self, path: Path) -> None:
        if path.parent not in (self.root, self.transaction_dir) or path.is_symlink():
            raise StateError("Invalid private transaction cleanup target")
        if path.exists():
            path.unlink()
            fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)

    def _cleanup_transaction(self, identifier: str) -> None:
        # The pair is already verified. Remove discoverability first so interrupted
        # cleanup cannot leave a journal pointing at a deleted rollback capsule.
        self._remove_private_file(self.journal_path)
        self._remove_private_file(self.transaction_dir / (identifier + ".checkpoint.uc"))
        self._remove_private_file(self.transaction_dir / (identifier + ".commit.uc"))

    def _capsule(self, identifier: str) -> dict:
        vault = self._transaction_vault()
        path = self.transaction_dir / (identifier + ".checkpoint.uc")
        try:
            capsule = json.loads(vault.open_checkpoint(private_read(path, 96 * 1024 * 1024)))
            if capsule.get("version") != 1 or capsule.get("id") != identifier or capsule.get("root") != str(self.root.resolve()):
                raise ValueError()
            self._validate(capsule["model"])
            vault_data = base64.b64decode(capsule["vault"], validate=True)
            vault._decode_entries(vault.open_checkpoint(vault_data))
            state_data = base64.b64decode(capsule["state"], validate=True) if capsule["state"] is not None else None
            if state_data is not None:
                self._validate(json.loads(state_data))
            capsule["vaultBytes"], capsule["stateBytes"] = vault_data, state_data
            return capsule
        except (ValueError, KeyError, TypeError):
            raise StateError("Workspace rollback capsule failed authentication or validation") from None

    def _rollback_capsule(self, capsule: dict, references=None) -> None:
        self._transaction_vault().restore_encrypted_snapshot(capsule["vaultBytes"])
        state_data = capsule["stateBytes"]
        with private_lock(self.root / ".state.lock"):
            if state_data is None:
                self._remove_private_file(self.path)
            else:
                atomic_write(self.path, state_data)
                if private_read(self.path) != state_data:
                    raise StateError("State rollback read-back verification failed")
        self._disk_revision = hashlib.sha256(state_data).hexdigest() if state_data is not None else None
        self._restore_model(capsule["model"], references)

    def recover_pending_transaction(self) -> str | None:
        """Finish a proven commit or roll back an interrupted transaction before use."""
        if self._active_transaction is not None:
            raise StateError("Cannot recover an active workspace transaction")
        with storage_lease(self.root, transaction=True):
            if not self.journal_path.exists():
                return None
            try:
                journal = json.loads(private_read(self.journal_path))
                identifier = str(uuid.UUID(journal["id"]))
                if journal.get("version") != 1 or identifier != journal["id"]:
                    raise ValueError()
            except (ValueError, KeyError, TypeError):
                raise StateError("The pending transaction journal is damaged; state was preserved") from None
            capsule = self._capsule(identifier)
            commit_path = self.transaction_dir / (identifier + ".commit.uc")
            committed = False
            if commit_path.exists():
                try:
                    commit = json.loads(self._transaction_vault().open_checkpoint(private_read(commit_path)))
                    committed = (commit.get("version") == 1 and commit.get("id") == identifier
                                 and commit.get("stateSHA256") == hashlib.sha256(private_read(self.path)).hexdigest()
                                 and commit.get("vaultSHA256") == hashlib.sha256(self._transaction_vault().encrypted_snapshot()).hexdigest())
                except (ValueError, OSError):
                    committed = False
            if committed:
                self._load_current()
                self.last_recovery = "committed"
            else:
                self._rollback_capsule(capsule)
                self.last_recovery = "rolled-back"
            self._cleanup_transaction(identifier)
            return self.last_recovery

    @contextmanager
    def transaction(self, reason: str = "mutation", *, source_fingerprint: str | None = None,
                    plan_fingerprint: str | None = None):
        """Atomically commit or recover the exact state/vault pair around a mutation.

        A GUI may wrap import/restore in an outer scope and verify child readiness
        before leaving it. Nested scopes join the outer transaction. No commit is
        reported until state, vault, and an authenticated commit marker are durable.
        """
        for fingerprint in (source_fingerprint, plan_fingerprint):
            if fingerprint is not None and not re.fullmatch(r"[a-f0-9]{64}", fingerprint):
                raise StateError("Transaction fingerprints must be SHA-256 values")
        if self._active_transaction is not None:
            changed = False
            for key, value in (("sourceFingerprint", source_fingerprint), ("planFingerprint", plan_fingerprint)):
                if value is not None and self._active_transaction.journal.get(key) is None:
                    self._active_transaction.journal[key] = value
                    changed = True
            if changed:
                self._write_journal(self._active_transaction.journal)
            yield self._active_transaction
            return
        with storage_lease(self.root, transaction=True):
            if self.journal_path.exists():
                self.recover_pending_transaction()
            vault = self._transaction_vault()
            before = private_read(self.path) if self.path.exists() else None
            actual_revision = hashlib.sha256(before).hexdigest() if before is not None else None
            if actual_revision != self._disk_revision:
                raise StateError("Workspace state changed in another process; reload before importing")
            identifier = str(uuid.uuid4())
            snapshot, references = self._clean(copy.deepcopy(self.data)), self._model_references()
            vault_bytes = vault.encrypted_snapshot()
            capsule = {"version": 1, "id": identifier, "root": str(self.root.resolve()),
                       "state": base64.b64encode(before).decode() if before is not None else None,
                       "model": snapshot, "vault": base64.b64encode(vault_bytes).decode()}
            journal = {"version": 1, "id": identifier, "reason": re.sub(r"[^a-z0-9_-]", "-", reason.lower())[:40],
                       "phase": "prepared", "createdAt": self.clock(), "events": [],
                       "sourceFingerprint": source_fingerprint, "planFingerprint": plan_fingerprint}
            checkpoint_path = self.transaction_dir / (identifier + ".checkpoint.uc")
            atomic_write(checkpoint_path, vault.seal_checkpoint(json.dumps(capsule, sort_keys=True).encode()))
            # Authenticate and reread the full checkpoint before exposing a mutation scope.
            verified = self._capsule(identifier)
            self._write_journal(journal)
            transaction = PersistentTransaction(self, journal)
            self._active_transaction = transaction
            vault._transaction_token = identifier
            committed = False
            try:
                self._failpoint("checkpoint:durable")
                yield transaction
                with transaction.step("state"):
                    self.save(scheduled=False)
                for credential in self._credential_ids(self.data):
                    vault.get(credential)
                state_bytes = private_read(self.path)
                expected = self._clean(self.data)
                if json.loads(state_bytes) != expected:
                    raise StateError("Workspace transaction read-back verification failed")
                committed_vault = vault.encrypted_snapshot()
                commit = {"version": 1, "id": identifier,
                          "stateSHA256": hashlib.sha256(state_bytes).hexdigest(),
                          "vaultSHA256": hashlib.sha256(committed_vault).hexdigest()}
                self._failpoint("commit:before")
                commit_path = self.transaction_dir / (identifier + ".commit.uc")
                atomic_write(commit_path, vault.seal_checkpoint(json.dumps(commit, sort_keys=True).encode()))
                if json.loads(vault.open_checkpoint(private_read(commit_path))) != commit:
                    raise StateError("Workspace commit marker verification failed")
                committed = True
                self._failpoint("commit:durable")
            except BaseException:
                if not committed:
                    try:
                        self._rollback_capsule(verified, references)
                    except BaseException as error:
                        raise StateError("Workspace rollback is pending recovery; original checkpoint was preserved") from error
                self._cleanup_transaction(identifier)
                raise
            finally:
                self._active_transaction = None
                vault._transaction_token = None
            self._cleanup_transaction(identifier)
            try:
                self.checkpoint("scheduled")
                self.last_backup_error = None
            except (VaultError, StateError, OSError):
                self.last_backup_error = "Recovery checkpoint unavailable; unlock the vault and persist again"

    def workspace(self, workspace_id: str) -> dict:
        for workspace in self.workspaces:
            if workspace["id"] == workspace_id:
                return workspace
        raise StateError("The selected workspace no longer exists")

    def window(self, workspace_id: str, window_id: str) -> dict:
        for window in self.workspace(workspace_id)["windows"]:
            if window["id"] == window_id:
                return window
        raise StateError("The selected window no longer exists")

    def close_window(self, workspace_id: str, window_id: str) -> dict:
        with storage_lease(self.root):
            return self._close_window(workspace_id, window_id)

    def _close_window(self, workspace_id: str, window_id: str) -> dict:
        original = copy.deepcopy(self.data)
        references = self._model_references()
        workspace = self.workspace(workspace_id)
        window = self.window(workspace_id, window_id)
        entry = {"id": str(uuid.uuid4()), "kind": "window", "closedAt": self.clock(),
                 "workspace": {key: copy.deepcopy(value) for key, value in workspace.items() if key != "windows"},
                 "window": copy.deepcopy(window), "index": workspace["windows"].index(window)}
        workspace["windows"].remove(window)
        if workspace.get("selectedWindowId") == window_id:
            workspace["selectedWindowId"] = workspace["windows"][0]["id"] if workspace["windows"] else None
        self.closed.insert(0, entry)
        try:
            self.save()
        except Exception:
            self._restore_model(original, references)
            raise
        return entry

    def close_workspace(self, workspace_id: str) -> dict:
        with storage_lease(self.root):
            return self._close_workspace(workspace_id)

    def _close_workspace(self, workspace_id: str) -> dict:
        original = copy.deepcopy(self.data)
        references = self._model_references()
        workspace = self.workspace(workspace_id)
        entry = {"id": str(uuid.uuid4()), "kind": "workspace", "closedAt": self.clock(),
                 "workspace": copy.deepcopy(workspace), "index": self.workspaces.index(workspace)}
        self.workspaces.remove(workspace)
        self.closed.insert(0, entry)
        if self.data.get("selectedWorkspaceId") == workspace_id:
            self.data["selectedWorkspaceId"] = self.workspaces[0]["id"] if self.workspaces else None
        try:
            self.save()
        except Exception:
            self._restore_model(original, references)
            raise
        return entry

    def restore_closed(self, entry_id: str) -> dict:
        with storage_lease(self.root):
            return self._restore_closed(entry_id)

    def _restore_closed(self, entry_id: str) -> dict:
        original = copy.deepcopy(self.data)
        references = self._model_references()
        entry = next((item for item in self.closed if item["id"] == entry_id), None)
        if entry is None:
            raise StateError("Closed item no longer exists")
        saved_workspace = copy.deepcopy(entry["workspace"])
        workspace = next((item for item in self.workspaces if item["id"] == saved_workspace["id"]), None)
        if entry["kind"] == "workspace":
            if workspace is not None:
                raise StateError("That workspace is already open")
            workspace = saved_workspace
            self.workspaces.insert(min(entry["index"], len(self.workspaces)), workspace)
        else:
            if workspace is None:
                workspace = saved_workspace
                workspace["windows"] = []
                self.workspaces.append(workspace)
            window = copy.deepcopy(entry["window"])
            if any(item["id"] == window["id"] for item in workspace["windows"]):
                raise StateError("That window is already open")
            window["status"] = "disconnected" if workspace["kind"] == "ssh" else "stopped"
            window["restoreOnly"] = True
            workspace["windows"].insert(min(entry["index"], len(workspace["windows"])), window)
            workspace["selectedWindowId"] = window["id"]
        for window in workspace["windows"]:
            window["restoreOnly"] = True
        self.data["selectedWorkspaceId"] = workspace["id"]
        self.closed.remove(entry)
        try:
            self.save()
        except Exception:
            self._restore_model(original, references)
            raise
        return workspace

    def backups(self) -> list[dict]:
        result = []
        if not self.backup_dir.exists():
            return result
        for path in self.backup_dir.glob("session-*.json"):
            if path.is_symlink():
                continue
            try:
                value = json.loads(private_read(path))
                metadata = value.get("recovery", {})
                if metadata.get("version") != 1:
                    continue
                result.append({"path": path, "createdAt": metadata["createdAt"],
                               "reason": metadata["reason"], "vaultFile": metadata.get("vaultFile")})
            except (OSError, ValueError, KeyError):
                continue
        return sorted(result, key=lambda item: item["createdAt"], reverse=True)

    def _credential_ids(self, value) -> set[str]:
        if isinstance(value, dict):
            result = {v for k, v in value.items() if k in ("credentialId", "commandCredentialId") and v}
            for child in value.values():
                result.update(self._credential_ids(child))
            return result
        if isinstance(value, list):
            result = set()
            for child in value:
                result.update(self._credential_ids(child))
            return result
        return set()

    def checkpoint(self, reason: str = "manual") -> Path | None:
        with storage_lease(self.root):
            if self.journal_path.exists() and self._active_transaction is None:
                raise StateError("A pending transaction must be recovered before creating a backup")
            return self._checkpoint(reason)

    def _checkpoint(self, reason: str) -> Path | None:
        now = self.clock()
        entries = self.backups()
        scheduled = [entry for entry in entries if entry["reason"] == "scheduled"]
        if reason == "scheduled" and scheduled and now - scheduled[0]["createdAt"] < 6 * 3600:
            return None
        snapshot = self._clean(copy.deepcopy(self.data))
        self._validate(snapshot)
        credential_ids = self._credential_ids(snapshot)
        ciphertext = None
        if credential_ids:
            if self.vault is None:
                raise VaultLocked("A complete backup requires the credential vault")
            for identifier in credential_ids:
                self.vault.get(identifier)
            ciphertext = self.vault.encrypted_snapshot()
        safe_reason = re.sub(r"[^a-zA-Z0-9_-]", "-", reason)[:40] or "manual"
        stem = f"session-{int(now * 1000)}-{safe_reason}-{uuid.uuid4()}"
        metadata = {"version": 1, "createdAt": now, "reason": reason}
        if ciphertext is not None:
            vault_path = self.backup_dir / (stem + ".vault.uc")
            atomic_write(vault_path, ciphertext)
            metadata.update(vaultFile=vault_path.name, vaultSHA256=hashlib.sha256(ciphertext).hexdigest())
        snapshot["recovery"] = metadata
        path = self.backup_dir / (stem + ".json")
        atomic_write(path, json.dumps(snapshot, ensure_ascii=False, sort_keys=True, indent=2).encode())
        self._prune_backups(now)
        return path

    def _prune_backups(self, now: float) -> None:
        count = 0
        for entry in self.backups():
            if entry["reason"] != "scheduled":
                continue
            count += 1
            if now - entry["createdAt"] <= 7 * 86400 and count <= 28:
                continue
            # Both names are derived from this owned archive's validated commit marker.
            entry["path"].unlink()
            name = entry.get("vaultFile")
            if name and Path(name).name == name and name == entry["path"].stem + ".vault.uc":
                companion = self.backup_dir / name
                if companion.is_file() and not companion.is_symlink():
                    companion.unlink()

    def restore_backup(self, path: str | Path) -> list[dict]:
        path = Path(path)
        if path.is_symlink() or path.parent.resolve() != self.backup_dir.resolve():
            raise StateError("Choose a recovery point from the UniConnect backup directory")
        try:
            snapshot = json.loads(private_read(path))
            self._validate(snapshot)
            metadata = snapshot.pop("recovery")
        except (KeyError, ValueError):
            raise StateError("Invalid recovery checkpoint") from None
        ciphertext = None
        if self._credential_ids(snapshot):
            name = metadata.get("vaultFile", "")
            if Path(name).name != name or not name or self.vault is None:
                raise StateError("Recovery checkpoint lacks its credential companion")
            ciphertext = private_read(self.backup_dir / name)
            if hashlib.sha256(ciphertext).hexdigest() != metadata.get("vaultSHA256"):
                raise StateError("Recovery credential companion does not match this snapshot")
        with self.transaction("restore", source_fingerprint=hashlib.sha256(private_read(path)).hexdigest(),
                              plan_fingerprint=hashlib.sha256(json.dumps(snapshot, sort_keys=True).encode()).hexdigest()) as transaction:
            self.checkpoint("before-restore")
            with transaction.step("vault"):
                if ciphertext is not None:
                    self.vault.merge_encrypted_snapshot(ciphertext)
            with transaction.step("model"):
                return self._restore_backup_model(snapshot)

    def _restore_backup_model(self, snapshot: dict) -> list[dict]:
        original = copy.deepcopy(self.data)
        references = self._model_references()
        restored = []
        for workspace in snapshot["workspaces"]:
            existing = next((item for item in self.workspaces if item["id"] == workspace["id"]), None)
            if existing is not None:
                # Restore alongside current work without duplicate live identities.
                workspace["id"] = str(uuid.uuid4())
                workspace["name"] += " (recovered)"
                old_selection = workspace.get("selectedWindowId")
                for window in workspace["windows"]:
                    old_id = window["id"]
                    window["id"] = str(uuid.uuid4())
                    if old_id == old_selection:
                        workspace["selectedWindowId"] = window["id"]
                    window["autoResume"] = False
                    window["duplicateSession"] = True
            for window in workspace["windows"]:
                window["restoreOnly"] = True
                window["status"] = "disconnected" if workspace["kind"] == "ssh" else "stopped"
            self.workspaces.append(workspace)
            restored.append(workspace)
        try:
            self.save()
        except Exception:
            self._restore_model(original, references)
            raise
        return restored
