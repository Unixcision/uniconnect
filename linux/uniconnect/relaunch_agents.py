"""Provider adapters and bounded transport for the target-side relaunch worker.

Unknown providers remain visible in the plan. Catalog syntax alone is never
treated as evidence that their effective conversation can be recovered safely.
"""

import base64
import hashlib
import json
from pathlib import Path
import shlex
import threading
import time

from .resume_catalog import AgentResumeCatalog
from .transport import Transport


# What this machine knows how to relaunch (contracts/relaunch-v1/proveedores.json, D7): the
# capability plus one relaunch.v1.<provider>.<kind> token per supported cell. The same worker
# runs locally and on an SSH box, so both kinds are announced. Only Codex for now: the Claude
# dialect is written (exit_claude) but relaunching closes the agent, and it has never run against
# a real Claude, so it stays out of the plan until a live test.
RELAUNCHABLE = ("codex",)
CAPABILITIES = ("relaunch.v1",) + tuple(f"relaunch.v1.{provider}.{kind}"
                                        for provider in RELAUNCHABLE for kind in ("local", "ssh"))


class RelaunchUnavailable(Exception):
    def __init__(self, cause):
        self.cause = cause
        super().__init__(cause)


class RelaunchAgents:
    def __init__(self, *, transport_factory=Transport, reconnect=None, clock=time.monotonic,
                 wait=None, catalog=None, validate=lambda candidate: True, resolve=None):
        self.transport_factory, self.reconnect, self.clock = transport_factory, reconnect, clock
        self.stopped = threading.Event()
        self.wait = wait or self.stopped.wait
        self.validate = validate
        self.resolve = resolve
        self.catalog = catalog or AgentResumeCatalog()
        self.source = self.worker_source()
        self.identity_helper = base64.b64encode(Path(__file__).with_name("agent_identity_hook.py").read_bytes()).decode()
        recovery = Path(__file__).resolve().parents[1] / "scripts/recovery.py"
        self.recovery_sha256 = hashlib.sha256(recovery.read_bytes()).hexdigest() if recovery.is_file() else None

    @staticmethod
    def worker_source():
        """Self-contained worker text: the catalogue module first, so the destination applies the
        no-prompt policy with the very same AgentResumeCatalog.apply_policy as this desktop."""
        here = Path(__file__)
        return here.with_name("resume_catalog.py").read_text() + "\n\n" + here.with_name("relaunch_worker.py").read_text()

    def close(self):
        # Stop observation, not the already admitted target-side close/reopen.
        # A later desktop recovers its journal. Never issue another start here.
        self.stopped.set()

    def request(self, candidate, action, **values):
        record = candidate["record"]
        request = {"action": action, "session": record.get("tmux"),
                   "socket": record.get("tmuxSocket") or ("uniconnect" if candidate.get("connection") else "uniconnect-local"),
                   "provider": candidate["provider"], "window_id": record["id"],
                   "catalog": self.catalog.providers, **values}
        request["recovery_sha256"] = self.recovery_sha256
        if action == "start":
            request["identity_helper"] = self.identity_helper
        payload = base64.b64encode(json.dumps(request).encode()).decode()
        transport = self.transport_factory(candidate.get("connection"), socket_name=request["socket"])
        try:
            result = transport.run(shlex.join(["python3", "-c", self.source, payload]), timeout=18)
        except Exception:
            raise RelaunchUnavailable("host_inaccesible") from None
        # Login-shell banners are allowed; only the bounded, versioned reply is parsed.
        lines = [line[len("UC_RELAUNCH_V1 "):] for line in result.stdout.splitlines()
                 if line.startswith("UC_RELAUNCH_V1 ")]
        if len(lines) != 1 or len(lines[0]) > 65536:
            raise RelaunchUnavailable("host_inaccesible")
        try:
            response = json.loads(lines[0])
        except ValueError:
            raise RelaunchUnavailable("host_inaccesible") from None
        if "error" in response:
            raise RelaunchUnavailable(response["error"])
        return response

    def probe(self, candidate, verb):
        if not candidate["record"].get("tmux"):
            raise RelaunchUnavailable("no_soportado")
        if verb != "transport.reconnect" and candidate.get("provider") in (None, "", "shell", "terminal"):
            # Ventana sin IA: se excluye con su causa, sin abrir SSH ni tocar el destino.
            raise RelaunchUnavailable("sin_ia")
        if verb != "transport.reconnect" and candidate.get("provider") not in RELAUNCHABLE:
            # Una IA que este equipo no relanza aún (ver RELAUNCHABLE): fuera, sin tocar el destino.
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
        # Probing a remote host can take seconds. Recheck after it, immediately
        # before dispatching the target-side atomic close/reopen operation.
        if not authorized():
            raise RelaunchUnavailable("permisos")
        if not self.validate(candidate):
            return {"state": "omitido", "cause": "generacion_cambiada"}
        try:
            result = self.request(candidate, "start", expected=proof, operation_id=operation_id)
        except RelaunchUnavailable as error:
            if error.cause != "host_inaccesible":
                raise
            # A lost response is not proof that the accepted target worker failed.
            return {"state": "planificado", "cause": "host_inaccesible"}
        if result["state"] in ("verificado", "fallido", "omitido", "necesita_usuario"):
            return result
        deadline = self.clock() + 95
        previous = None
        reachable = True
        while self.clock() < deadline and not self.stopped.is_set():
            try:
                result = self.request(candidate, "status", expected=proof, operation_id=operation_id)
            except Exception:
                reachable = False
                # The target worker is independent of this SSH connection.
                # Read the SAME journal after a cut; never submit another start.
                self.wait(1)
                continue
            reachable = True
            if result != previous:
                changed(result)
                previous = result
            if result["state"] in ("verificado", "fallido", "omitido", "necesita_usuario"):
                return result
            self.wait(0.5)
        # A live target may be queued behind another pane's account startup
        # lock. Preserve its phase; a bounded UI wait is not a network failure.
        return result if reachable else {"state": result["state"], "cause": "host_inaccesible"}
