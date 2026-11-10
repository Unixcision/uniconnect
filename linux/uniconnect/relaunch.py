"""Plan/apply/status for relaunch.v1, independent of GTK and provider processes.

Only the execution adapter may affect a target. Admission is persisted before
dispatch so a repeated apply (including after a desktop crash) never closes an
agent twice. No command lines, credentials or terminal contents enter the log.
"""

import copy
import datetime
import re
import hashlib
import hmac
import json
import secrets
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

from .mobile_protocol import RPCError
from .event_log import NullLog
from .vault import atomic_write, private_read


VERBS = {"agent.relaunch", "agent.update", "transport.reconnect", "agent.continue", "agent.recover"}
TERMINAL = {"verificado", "necesita_usuario", "fallido", "omitido"}
MODEL = re.compile(r"[a-z0-9.\-\[\]]{2,40}")
EFFORTS = ("low", "medium", "high", "xhigh", "max")
# Lo que el plan enseña de cada Claude antes de confirmar, y lo que vuelve en su resultado.
PLAN_FIELDS = ("background", "draft", "context_tokens", "message")
RESULT_FIELDS = ("state", "cause", "effective_id", "escalation", "dropped_options", "version", "model", "effort",
                 "background_saved", "message_sent", "draft_restored", "answered")
ANSWERED_TEXT = {"codex_update_skip": "diálogo de actualización de Codex: Skip",
                 "claude_trust_folder": "confianza de carpeta de Claude: Yes, I trust this folder",
                 "codex_retry_open_elsewhere": "Codex: «abierta en otra app», reintentado con r"}
PHASES = {
    "agent.relaunch": ("planificado", "cerrando", "reabriendo", "verificado"),
    # relaunch-v1 (09-11): «Actualizar Claude» es el mismo proceso, con las mismas fases.
    "agent.update": ("planificado", "cerrando", "reabriendo", "verificado"),
    "transport.reconnect": ("planificado", "reenganchando", "verificado"),
    "agent.continue": ("planificado", "entregando", "verificado"),
    "agent.recover": ("planificado", "cerrando", "reabriendo", "entregando", "verificado"),
}


class RelaunchService:
    def __init__(self, root, adapter, *, clock=time.time, submit=None, writer=atomic_write, log=None):
        self.root, self.adapter, self.clock, self.writer = root, adapter, clock, writer
        self.log = log or NullLog()  # log.v1: cada plan, apply y resultado deja su línea.
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.pool = None if submit else ThreadPoolExecutor(max_workers=4, thread_name_prefix="uc-relaunch")
        self.submit = submit or self.pool.submit
        self.lock = threading.RLock()
        self.plans = {}
        self.running = set()
        self.closed = False

    def close(self):
        with self.lock:
            self.closed = True
        if hasattr(self.adapter, "close"):
            self.adapter.close()
        if self.pool:
            self.pool.shutdown(wait=False, cancel_futures=True)

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

    def check(self, authorized):
        if self.closed or not authorized():
            raise RPCError("token_no_valido", "El dispositivo ya no tiene autorización")

    @staticmethod
    def identifier(value):
        try:
            if not isinstance(value, str) or str(uuid.UUID(value)) != value:
                raise ValueError()
        except ValueError:
            raise RPCError("operacion_desconocida", "No se reconoce la operación") from None
        return value

    @staticmethod
    def options(verb, value):
        """agent.update admite modelo y effort (la clave que falta = «igual que estaba»); el resto, nada."""
        if value is None:
            return {} if verb == "agent.update" else None
        if (verb != "agent.update" or not isinstance(value, dict) or set(value) - {"model", "effort"}
                or ("model" in value and not (isinstance(value["model"], str) and MODEL.fullmatch(value["model"])))
                or ("effort" in value and value["effort"] not in EFFORTS)):
            raise RPCError("opciones_no_validas", "Opciones no válidas para esta operación")
        return dict(value)

    def plan(self, verb, candidates, owner, authorized, options=None):
        self.check(authorized)
        if verb not in VERBS:
            raise RPCError("alcance_no_valido", "Operación de IA no válida")
        options = self.options(verb, options)
        selected, excluded, seen = [], [], set()
        for candidate in candidates:
            self.check(authorized)
            label = candidate["label"]
            try:
                proof = (self.adapter.probe(candidate, verb, options=options) if verb == "agent.update"
                         else self.adapter.probe(candidate, verb))
            except Exception as error:
                excluded.append({"label": label, "cause": getattr(error, "cause", "host_inaccesible")})
                self.log.info("relaunch", "relaunch.excluded", window=(candidate.get("record") or {}).get("id"),
                              detail={"cause": excluded[-1]["cause"], "provider": candidate.get("provider")})
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
                         "generation": proof["generation"], "state": "planificado",
                         **({"active": True} if proof.get("active") is True else {}),
                         **({"warning": proof["warning"]} if proof.get("warning") else {}),
                         **({"dropped_options": proof["dropped_options"]} if proof.get("dropped_options") else {}),
                         **{key: proof[key] for key in PLAN_FIELDS if key in proof},
                         **{key: (proof.get("installation") or {}).get(key) for key in ("version", "installed")
                            if (proof.get("installation") or {}).get(key)}}
                        for candidate, proof in selected], "excluded": excluded}
        if verb == "agent.update":
            response["options"] = options
        if any("context_tokens" in proof for _, proof in selected):
            # El mensaje tras reabrir es lo que gasta cupo: se suma solo el de quien lo recibirá.
            response["estimated_tokens"] = sum(proof.get("context_tokens") or 0 for _, proof in selected
                                               if proof.get("message"))
        self.log.info("relaunch", "relaunch.plan", op=identifier,
                      detail={"verb": verb, "targets": len(selected), "excluded": len(excluded)})
        self.check(authorized)
        with self.lock:
            self.plans = {key: value for key, value in self.plans.items() if value["expires"] > self.clock()}
            if len(self.plans) >= 64:
                raise RPCError("busy", "Hay demasiados planes pendientes")
            self.plans[identifier] = {"owner": owner, "hash": self.token_hash(token), "expires": expires,
                                      "verb": verb, "options": options, "selected": selected, "response": response}
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
        response = {"operation_id": value["operation_id"], "recovered": recovered,
                    "operation_state": "terminada" if all(r["state"] in TERMINAL for r in results) else "en_curso",
                    "results": results}
        if value.get("verb") == "agent.update":
            response["updates"] = copy.deepcopy(value.get("updates", []))
        return response

    def status(self, identifier, owner, authorized):
        self.check(authorized)
        with self.lock:
            value = self.read(identifier)
            if value is None or value["owner"] != owner:
                raise RPCError("operacion_desconocida", "No se reconoce la operación de este dispositivo")
            for result, target in zip(value["results"], value.get("targets", [])):
                job = (identifier, result["key"])
                if result["state"] not in TERMINAL and job not in self.running:
                    if value.get("dispatch", {}).get(result["key"]) == "not_sent":
                        self.not_sent(identifier, result["key"])
                        continue
                    self.running.add(job)
                    self.submit(self.recover, identifier, target, authorized)
            return self.response(self.read(identifier), True)

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
                     "verb": plan["verb"], "options": plan.get("options"), "created_at": self.clock(),
                     "dispatch": {proof["key"]: "not_sent" for _, proof in plan["selected"]},
                     "targets": [{"proof": proof, "record": {key: candidate.get("record", {}).get(key)
                                   for key in ("id", "tmux", "tmuxSocket", "agent", "cwd", "sessionId")},
                                  "workspace_id": candidate.get("workspace", {}).get("id"),
                                  "credential_id": candidate.get("workspace", {}).get("credentialId")}
                                 for candidate, proof in plan["selected"]],
                     "results": [{"key": proof["key"], "state": "planificado"}
                                 for _, proof in plan["selected"]]}
            self.check(authorized)
            self.save(identifier, value)  # Acceptance MUST survive before any effect.
            self.log.info("relaunch", "relaunch.apply", op=identifier,
                          detail={"verb": plan["verb"], "targets": len(plan["selected"])})
            # Reserve all jobs before releasing admission. A concurrent status
            # must not mistake an accepted-but-not-yet-submitted job for a crash.
            self.running.update((identifier, proof["key"]) for _, proof in plan["selected"])
            response = self.response(value, False)
            self.plans.pop(identifier)
        if plan["verb"] == "agent.update":
            for installation, selected in self.installations(plan["selected"]).items():
                try:
                    self.submit(self.update_then_execute, identifier, installation, selected, plan.get("options"), authorized)
                except Exception:
                    for _, proof in selected:
                        self.not_sent(identifier, proof["key"])
            return response
        for candidate, proof in plan["selected"]:
            self.dispatch_one(identifier, plan["verb"], candidate, proof, authorized)
        return response

    def dispatch_one(self, identifier, verb, candidate, proof, authorized, **extra):
        try:
            future = self.submit(self.execute, identifier, verb, candidate, proof, authorized, **extra)
            if hasattr(future, "add_done_callback"):
                future.add_done_callback(lambda value, key=proof["key"]:
                    self.not_sent(identifier, key) if value.cancelled() else None)
        except Exception:
            self.not_sent(identifier, proof["key"])

    @staticmethod
    def installations(selected):
        """Una instalación = equipo destino + su lanzador de Claude (relaunch-v1, 09-11)."""
        groups = {}
        for candidate, proof in selected:
            host = candidate.get("connection") or "local"
            launcher = (proof.get("installation") or {}).get("launcher")
            groups.setdefault(json.dumps([host, launcher]), []).append((candidate, proof))
        return groups

    def update_then_execute(self, identifier, installation, selected, options, authorized):
        """`claude update` UNA vez por instalación, antes de cerrar nada de ella; si falla, no se cierra nada."""
        host, launcher = json.loads(installation)
        label = "local" if host == "local" else (selected[0][0].get("workspace") or {}).get("hostLabel") or "ssh"
        try:
            self.check(authorized)
            update = (self.adapter.update(selected[0][0], selected[0][1]) if launcher
                      else {"state": "fallida", "from": None, "to": None})
        except Exception:
            update = {"state": "fallida", "from": None, "to": None}
        entry = {"host": label, "state": update.get("state", "fallida"), "from": update.get("from"), "to": update.get("to")}
        with self.lock:
            value = self.read(identifier)
            value.setdefault("updates", []).append(entry)
            self.save(identifier, value)
        self.log.write("info" if entry["state"] != "fallida" else "error", "relaunch", "relaunch.claude_update",
                       op=identifier, detail=entry)
        for candidate, proof in selected:
            if entry["state"] == "fallida":
                with self.lock:
                    self.update(identifier, proof["key"], {"state": "omitido", "cause": "actualizacion_fallida"})
                    self.running.discard((identifier, proof["key"]))
                continue
            self.dispatch_one(identifier, "agent.update", candidate, proof, authorized,
                              options=options, updated_to=entry["to"])

    def not_sent(self, identifier, key):
        """Only durable pre-dispatch evidence permits saying no effect was sent."""
        with self.lock:
            try:
                value = self.read(identifier)
                if value.get("dispatch", {}).get(key) == "not_sent":
                    self.update(identifier, key, {"state": "omitido", "cause": "no_enviado"})
            finally:
                self.running.discard((identifier, key))

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
                previous.pop("cause", None)
                previous.update({k: v for k, v in result.items() if k in RESULT_FIELDS})
                if previous["state"] in TERMINAL:
                    self.log_result(identifier, value, previous)
            self.save(identifier, value)

    # log.v1 por escalón: el trabajador corre en el destino (a veces por SSH) y no escribe aquí,
    # así que el escritorio deja las líneas cuando llega el resultado, con el último escalón.
    ESCALATION_EVENTS = {"kill_process": ("relaunch.exit_timeout", "relaunch.kill_process"),
                         "respawn_pane": ("relaunch.exit_timeout", "relaunch.respawn_pane"),
                         "recreate_session": ("relaunch.exit_timeout", "relaunch.kill_session",
                                              "relaunch.session_recreated")}

    def log_result(self, identifier, value, result):
        target = next((item for item in value.get("targets", []) if item["proof"]["key"] == result["key"]), {})
        record = target.get("record") or {}
        fields = {"op": identifier, "window": record.get("id"), "workspace": target.get("workspace_id")}
        if result["state"] == "verificado":
            for event in self.ESCALATION_EVENTS.get(result.get("escalation"), ()):
                self.log.write("info" if event == "relaunch.session_recreated" else "warn", "relaunch", event, **fields)
            for option in result.get("dropped_options", []):
                self.log.warn("relaunch", "relaunch.option_dropped", **fields, detail={"option": option})
            for dialog in result.get("answered", []):
                self.log.info("relaunch", "relaunch.dialog_answered", **fields,
                              detail={"dialog": dialog, "text": ANSWERED_TEXT.get(dialog, dialog)})
            self.log.info("relaunch", "relaunch.resumed", **fields,
                          detail={"provider": record.get("agent"), "escalation": result.get("escalation")})
        else:
            self.log.error("relaunch", "relaunch.failed", **fields,
                           detail={"state": result["state"], "cause": result.get("cause")})

    def execute(self, identifier, verb, candidate, proof, authorized, **extra):
        try:
            with self.lock:
                self.check(authorized)
                value = self.read(identifier)
                # Persist BEFORE entering an adapter that can send effects.
                # A crash after this boundary is UNKNOWN, not proof of delivery
                # or of non-delivery. Older journals lack this evidence and must
                # also be recovered conservatively.
                value.setdefault("dispatch", {})[proof["key"]] = "possible"
                self.save(identifier, value)
            result = self.adapter.execute(candidate, verb, proof, identifier,
                lambda result: self.update(identifier, proof["key"], result),
                lambda: not self.closed and authorized(), **extra)
            self.update(identifier, proof["key"], result)
        except Exception as error:
            if self.read(identifier).get("dispatch", {}).get(proof["key"]) == "not_sent":
                self.not_sent(identifier, proof["key"])
            else:
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
            cause = getattr(error, "cause", "sin_autoridad")
            # A queued observer can lose its desktop/permission before it runs.
            # That prevents reading; it does NOT prove the admitted remote
            # close/reopen failed. Keep the original phase recoverable by the
            # same owner after access returns, without dispatching another start.
            observation_unavailable = isinstance(error, RPCError) or cause in ("host_inaccesible", "permisos")
            with self.lock:
                previous = next(row for row in self.read(identifier)["results"] if row["key"] == key)
                self.update(identifier, key, {"state": previous["state"] if observation_unavailable else "necesita_usuario",
                                               "cause": cause})
        finally:
            with self.lock:
                self.running.discard((identifier, key))
