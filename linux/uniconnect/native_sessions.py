"""Observe real pane-scoped native IDs and persist them through the workspace store."""

import copy
import json
import re
import shlex
import time
import uuid

from .transport import TmuxCommand, Transport


class NativeSessions:
    def __init__(self, owner, *, transport=Transport, clock=time.time):
        self.owner, self.transport, self.clock = owner, transport, clock
        self.pending = set()

    @staticmethod
    def read(transport):
        # One metadata query per connection/socket, never per byte or keystroke.
        # No titles, screen contents, process argv, or provider transcripts.
        output = transport.run(TmuxCommand._binary(transport.socket_name) +
            " list-panes -a -F " + shlex.quote(
                "#{session_name}\t#{pane_id}\t#{pane_pid}\t#{@uniconnect_native_generation}\t#{@uniconnect_native_identity}"),
            timeout=8, check=False).stdout
        proofs = []
        for line in output.splitlines()[:2048]:
            if len(line) > 32768:
                continue
            parts = line.split("\t", 4)
            if len(parts) != 5 or not parts[4]:
                continue
            try:
                proof = json.loads(parts[4])
                if (proof.get("version") == 1 and proof.get("tmux_pane") == parts[1]
                        and str(proof.get("pane_pid")) == parts[2] and proof.get("generation") == parts[3]
                        and isinstance(proof.get("window_id"), str) and 0 < len(proof["window_id"]) <= 128
                        and proof.get("agent") in ("claude", "codex")
                        and re.fullmatch(r"[a-f0-9]{32}", parts[3])
                        and re.fullmatch(r"[A-Za-z0-9_-]{1,160}", proof.get("session_id", ""))):
                    proofs.append({**proof, "tmux": parts[0]})
            except (ValueError, TypeError, AttributeError):
                continue
        return proofs

    def poll(self):
        owner = self.owner
        if owner._closed or owner.locked or owner.store._active_transaction is not None:
            return
        groups = {}
        for surface in tuple(owner.surfaces.values()):
            record, workspace = surface.record, surface.workspace
            if surface.disposed or not surface.pid or record.get("agent") not in ("claude", "codex") or not record.get("tmux"):
                continue
            socket = record.get("tmuxSocket") or ("uniconnect" if workspace["kind"] == "ssh" else "uniconnect-local")
            # Local boxes share one server; remote boxes keep their credential scope.
            key = (workspace["id"] if workspace["kind"] == "ssh" else "local", socket)
            groups.setdefault(key, []).append((surface, surface.generation, record, workspace))
        for key, targets in groups.items():
            if key in self.pending:
                continue
            try:
                workspace = targets[0][3]
                command = owner.connection(workspace) if workspace["kind"] == "ssh" else None
                transport = self.transport(command, socket_name=key[1])
            except Exception:
                continue
            self.pending.add(key)
            def work(transport=transport):
                try:
                    return self.read(transport)
                except Exception:
                    return []
            def done(proofs, key=key, targets=targets):
                self.pending.discard(key)
                if owner._closed or owner.locked or owner.store._active_transaction is not None:
                    return
                for surface, generation, record, workspace in targets:
                    if (surface.disposed or not surface.pid or surface.generation != generation
                            or owner.surfaces.get(record["id"]) is not surface or surface.record is not record
                            or surface.workspace is not workspace or record not in workspace["windows"]):
                        continue
                    matching = [proof for proof in proofs if proof["window_id"] == record["id"]
                                and proof["tmux"] == record["tmux"] and proof["agent"] == record["agent"]]
                    if len(matching) != 1:
                        continue
                    proof = matching[0]
                    tmux_key = next((item for item in surface._ownership_keys if item[0] == "tmux"), None)
                    if tmux_key is None:
                        continue
                    agent_key = ("agent", tmux_key[1], record["agent"], proof["session_id"])
                    registry = owner._terminal_owners
                    if registry.get(agent_key) not in (None, surface):
                        continue
                    if self.persist(record, proof):
                        for old in list(surface._ownership_keys):
                            if old[0] == "agent":
                                surface._ownership_keys.remove(old)
                                if registry.get(old) is surface:
                                    registry.pop(old)
                        surface._ownership_keys.append(agent_key)
                        registry[agent_key] = surface
                        surface.update_status(surface.status)
            owner.background(work, done)

    def persist(self, record, proof):
        """Commit ID and history together; imported history entries remain untouched."""
        session = proof["session_id"]
        if record.get("sessionId") == session:
            return False
        before = copy.deepcopy(record)
        history = copy.deepcopy(record.get("history", []))
        now = self.clock()
        for identifier in (record.get("sessionId"), session):
            if identifier and not any(item.get("agent") == record["agent"] and item.get("sessionId") == identifier for item in history):
                history.append({"id": str(uuid.uuid4()), "agent": record["agent"], "sessionId": identifier,
                                "firstSeenAt": now, "lastSeenAt": now})
        record.update(sessionId=session, history=history)
        try:
            self.owner.store.save()
        except Exception:
            record.clear()
            record.update(before)
            raise
        return True
