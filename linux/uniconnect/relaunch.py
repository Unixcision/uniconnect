"""Plan/apply/status for relaunch.v1, independent of GTK and provider processes.

Only the execution adapter may affect a target. Admission is persisted before
dispatch so a repeated apply (including after a desktop crash) never closes an
agent twice. No command lines, credentials or terminal contents enter the log.
"""

import copy
import datetime
import hashlib
import hmac
import json
import secrets
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

from .mobile_protocol import RPCError
from .vault import atomic_write, private_read


VERBS = {"agent.relaunch", "transport.reconnect", "agent.continue"}
TERMINAL = {"verificado", "necesita_usuario", "fallido", "omitido"}
PHASES = {
    "agent.relaunch": ("planificado", "cerrando", "reabriendo", "verificado"),
    "transport.reconnect": ("planificado", "reenganchando", "verificado"),
    "agent.continue": ("planificado", "entregando", "verificado"),
}


class RelaunchService:
    def __init__(self, root, adapter, *, clock=time.time, submit=None, writer=atomic_write):
        self.root, self.adapter, self.clock, self.writer = root, adapter, clock, writer
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.pool = None if submit else ThreadPoolExecutor(max_workers=4, thread_name_prefix="uc-relaunch")
        self.submit = submit or self.pool.submit
        self.lock = threading.RLock()
        self.plans = {}
        self.running = set()

    @staticmethod
    def scope(value, machine_id, workspaces):
        if (not isinstance(value, dict) or set(value) != {"kind", "id"}
                or value.get("kind") not in ("window", "workspace", "machine")
                or not isinstance(value.get("id"), str) or not value["id"]):
            raise RPCError("alcance_no_valido", "Elige una ventana, un espacio o un equipo concreto")
        kind, identifier = value["kind"], value["id"]
        if kind == "machine" and identifier != machine_id:
            raise RPCError("alcance_no_valido", "El equipo no corresponde a esta conexión")
        selected = [(box, record) for box in workspaces for record in box.get("windows", [])
                    if kind == "machine" or (kind == "workspace" and box["id"] == identifier)
                    or (kind == "window" and record["id"] == identifier)]
        if kind != "machine" and not selected and not (kind == "workspace" and any(
                box["id"] == identifier for box in workspaces)):
            raise RPCError("alcance_no_valido", "El objetivo ya no existe")
        if len(selected) > 512:
            raise RPCError("alcance_no_valido", "El alcance supera 512 ventanas; divide la operación")
        return selected

    @staticmethod
    def check(authorized):
        if not authorized():
            raise RPCError("token_no_valido", "El dispositivo ya no tiene autorización")

    @staticmethod
    def identifier(value):
        try:
            if not isinstance(value, str) or str(uuid.UUID(value)) != value:
                raise ValueError()
        except ValueError:
            raise RPCError("operacion_desconocida", "No se reconoce la operación") from None
        return value

    def plan(self, verb, candidates, owner, authorized):
        self.check(authorized)
        if verb not in VERBS:
            raise RPCError("alcance_no_valido", "Operación de IA no válida")
        selected, excluded, seen = [], [], set()
        for candidate in candidates:
            self.check(authorized)
            label = candidate["label"]
            try:
                proof = self.adapter.probe(candidate, verb)
            except Exception as error:
                excluded.append({"label": label, "cause": getattr(error, "cause", "host_inaccesible")})
                continue
            if proof["key"] in seen:
                excluded.append({"label": label, "cause": "duplicado"})
                continue
            seen.add(proof["key"])
            selected.append((candidate, proof))
        identifier, token = str(uuid.uuid4()), secrets.token_urlsafe(32)
        expires = self.clock() + 120
        response = {"operation_id": identifier, "token": token,
                    "expires_at": datetime.datetime.fromtimestamp(expires, datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
                    "verb": verb, "targets": [
                        {"key": proof["key"], "label": candidate["label"], "provider": candidate["provider"],
                         "generation": proof["generation"], "state": "planificado"}
                        for candidate, proof in selected], "excluded": excluded}
        self.check(authorized)
        with self.lock:
            self.plans = {key: value for key, value in self.plans.items() if value["expires"] > self.clock()}
            if len(self.plans) >= 64:
                raise RPCError("busy", "Hay demasiados planes pendientes")
            self.plans[identifier] = {"owner": owner, "hash": self.token_hash(token), "expires": expires,
                                      "verb": verb, "selected": selected, "response": response}
        return copy.deepcopy(response)

    @staticmethod
    def token_hash(token):
        if not isinstance(token, str) or not 16 <= len(token) <= 256:
            raise RPCError("token_no_valido", "El token no es válido")
        return hashlib.sha256(token.encode()).hexdigest()

    def read(self, identifier):
        path = self.root / (self.identifier(identifier) + ".json")
        if not path.exists():
            return None
        return json.loads(private_read(path, maximum=1024 * 1024))

    def save(self, identifier, value):
        self.writer(self.root / (identifier + ".json"), json.dumps(value, ensure_ascii=True).encode())

    @staticmethod
    def response(value, recovered):
        results = copy.deepcopy(value["results"])
        return {"operation_id": value["operation_id"], "recovered": recovered,
                "operation_state": "terminada" if all(r["state"] in TERMINAL for r in results) else "en_curso",
                "results": results}

    def status(self, identifier, owner, authorized):
        self.check(authorized)
        with self.lock:
            value = self.read(identifier)
            if value is None or value["owner"] != owner:
                raise RPCError("operacion_desconocida", "No se reconoce la operación de este dispositivo")
            for result, target in zip(value["results"], value.get("targets", [])):
                job = (identifier, result["key"])
                if result["state"] not in TERMINAL and job not in self.running:
                    self.running.add(job)
                    self.submit(self.recover, identifier, target, authorized)
            return self.response(value, True)

    def apply(self, identifier, token, owner, authorized):
        self.identifier(identifier)
        digest = self.token_hash(token)
        self.check(authorized)
        with self.lock:
            value = self.read(identifier)
            if value is not None:
                if value["owner"] != owner or not hmac.compare_digest(value["hash"], digest):
                    raise RPCError("token_no_valido", "El token no pertenece a este dispositivo y operación")
                return self.response(value, True)
            plan = self.plans.get(identifier)
            if plan is None:
                raise RPCError("operacion_desconocida", "El plan ya no está disponible; prepara otro")
            if plan["owner"] != owner or not hmac.compare_digest(plan["hash"], digest):
                raise RPCError("token_no_valido", "El token no pertenece a este dispositivo y operación")
            if self.clock() >= plan["expires"]:
                raise RPCError("token_caducado", "El plan ha caducado; vuelve a previsualizar")
            value = {"operation_id": identifier, "owner": owner, "hash": digest,
                     "verb": plan["verb"], "created_at": self.clock(),
                     "targets": [{"proof": proof, "record": {key: candidate.get("record", {}).get(key)
                                   for key in ("id", "tmux", "tmuxSocket", "agent", "cwd", "sessionId")},
                                  "workspace_id": candidate.get("workspace", {}).get("id"),
                                  "credential_id": candidate.get("workspace", {}).get("credentialId")}
                                 for candidate, proof in plan["selected"]],
                     "results": [{"key": proof["key"], "state": "planificado"}
                                 for _, proof in plan["selected"]]}
            self.check(authorized)
            self.save(identifier, value)  # Acceptance MUST survive before any effect.
            # Reserve all jobs before releasing admission. A concurrent status
            # must not mistake an accepted-but-not-yet-submitted job for a crash.
            self.running.update((identifier, proof["key"]) for _, proof in plan["selected"])
            response = self.response(value, False)
            self.plans.pop(identifier)
        for candidate, proof in plan["selected"]:
            try:
                self.submit(self.execute, identifier, plan["verb"], candidate, proof, authorized)
            except Exception:
                with self.lock:
                    self.running.discard((identifier, proof["key"]))
                    self.update(identifier, proof["key"], {"state": "fallido", "cause": "sin_autoridad"})
        return response

    def update(self, identifier, key, result):
        with self.lock:
            value = self.read(identifier)
            for previous in value["results"]:
                if previous["key"] != key or previous["state"] in TERMINAL:
                    continue
                state = result["state"]
                phases = PHASES[value["verb"]]
                if state not in TERMINAL and (state not in phases or phases.index(state) < phases.index(previous["state"])):
                    raise ValueError("invalid_relaunch_transition")
                previous.update({k: v for k, v in result.items() if k in ("state", "cause", "effective_id")})
            self.save(identifier, value)

    def execute(self, identifier, verb, candidate, proof, authorized):
        try:
            self.check(authorized)
            result = self.adapter.execute(candidate, verb, proof, identifier,
                lambda result: self.update(identifier, proof["key"], result), authorized)
            self.update(identifier, proof["key"], result)
        except Exception as error:
            self.update(identifier, proof["key"], {"state": "fallido", "cause": getattr(error, "cause", "host_inaccesible")})
        finally:
            with self.lock:
                self.running.discard((identifier, proof["key"]))

    def recover(self, identifier, target, authorized):
        key = target["proof"]["key"]
        try:
            self.check(authorized)
            result = self.adapter.recover(target, identifier)
            self.update(identifier, key, result)
        except Exception as error:
            self.update(identifier, key, {"state": "necesita_usuario", "cause": getattr(error, "cause", "sin_autoridad")})
        finally:
            with self.lock:
                self.running.discard((identifier, key))
