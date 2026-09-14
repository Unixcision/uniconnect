"""Provider adapters and bounded transport for the target-side relaunch worker.

Unknown providers remain visible in the plan. Catalog syntax alone is never
treated as evidence that their effective conversation can be recovered safely.
"""

import base64
import json
from pathlib import Path
import shlex
import threading
import time

from .resume_catalog import AgentResumeCatalog
from .transport import Transport


class RelaunchUnavailable(Exception):
    def __init__(self, cause):
        self.cause = cause
        super().__init__(cause)


class RelaunchAgents:
    def __init__(self, *, transport_factory=Transport, reconnect=None, clock=time.monotonic,
                 wait=None, catalog=None, validate=lambda candidate: True, resolve=None):
        self.transport_factory, self.reconnect, self.clock = transport_factory, reconnect, clock
        self.wait = wait or threading.Event().wait
        self.validate = validate
        self.resolve = resolve
        self.catalog = catalog or AgentResumeCatalog()
        self.source = Path(__file__).with_name("relaunch_worker.py").read_text()
        self.identity_helper = base64.b64encode(Path(__file__).with_name("agent_identity_hook.py").read_bytes()).decode()

    def request(self, candidate, action, **values):
        record = candidate["record"]
        request = {"action": action, "session": record.get("tmux"),
                   "socket": record.get("tmuxSocket") or ("uniconnect" if candidate.get("connection") else "uniconnect-local"),
                   "provider": candidate["provider"], "window_id": record["id"],
                   "catalog": self.catalog.providers, **values}
        if action == "start":
            request["identity_helper"] = self.identity_helper
        payload = base64.b64encode(json.dumps(request).encode()).decode()
        transport = self.transport_factory(candidate.get("connection"), socket_name=request["socket"])
        result = transport.run(shlex.join(["python3", "-c", self.source, payload]), timeout=18)
        # Login-shell banners are allowed; only the bounded, versioned reply is parsed.
        lines = [line[len("UC_RELAUNCH_V1 "):] for line in result.stdout.splitlines()
                 if line.startswith("UC_RELAUNCH_V1 ")]
        if len(lines) != 1 or len(lines[0]) > 65536:
            raise RelaunchUnavailable("host_inaccesible")
        response = json.loads(lines[0])
        if "error" in response:
            raise RelaunchUnavailable(response["error"])
        return response

    def probe(self, candidate, verb):
        if not candidate["record"].get("tmux"):
            raise RelaunchUnavailable("no_soportado")
        return self.request(candidate, "inspect", verb=verb)

    def recover(self, target, operation_id):
        if self.resolve is None:
            raise RelaunchUnavailable("sin_autoridad")
        candidate = self.resolve(target)
        return self.request(candidate, "status", expected=target["proof"], operation_id=operation_id)

    def execute(self, candidate, verb, proof, operation_id, changed, authorized):
        if not authorized():
            raise RelaunchUnavailable("permisos")
        if not self.validate(candidate):
            return {"state": "omitido", "cause": "generacion_cambiada"}
        current = self.probe(candidate, verb)
        if current != proof:
            return {"state": "omitido", "cause": "generacion_cambiada"}
        if verb == "transport.reconnect":
            changed({"state": "reenganchando"})
            if self.reconnect is None:
                raise RelaunchUnavailable("no_soportado")
            self.reconnect(candidate, proof, authorized)
            if self.probe(candidate, verb) != proof:
                return {"state": "fallido", "cause": "generacion_cambiada"}
            return {"state": "verificado"}
        if verb == "agent.continue":
            # Until a provider exposes a verifiable input receipt, never type
            # into a possibly active permission dialog or claim a queued key is ACKed.
            return {"state": "necesita_usuario", "cause": "no_soportado"}
        result = self.request(candidate, "start", expected=proof, operation_id=operation_id)
        if result["state"] in ("verificado", "fallido", "omitido", "necesita_usuario"):
            return result
        deadline = self.clock() + 95
        previous = None
        while self.clock() < deadline:
            try:
                result = self.request(candidate, "status", expected=proof, operation_id=operation_id)
            except Exception:
                # The target worker is independent of this SSH connection.
                # Read the SAME journal after a cut; never submit another start.
                self.wait(1)
                continue
            if result != previous:
                changed(result)
                previous = result
            if result["state"] in ("verificado", "fallido", "omitido", "necesita_usuario"):
                return result
            self.wait(0.5)
        return {"state": "necesita_usuario", "cause": "host_inaccesible"}
