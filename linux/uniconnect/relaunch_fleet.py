"""Client fan-out: 'global' freezes machine plans, never invents a server scope."""

from concurrent.futures import ThreadPoolExecutor
import socket
import uuid

from .mobile_access import tailnet_address
from .machine_directory import endpoint
from .mobile_protocol import FrameDecoder, RPCError, encode_frame


class RelaunchFleet:
    def __init__(self, local, peers, *, call=None):
        self.local, self.peers = local, tuple(peers)
        self.call = call or self.rpc
        self.hosts = []

    @classmethod
    def restore(cls, local, receipts, *, call=None):
        fleet = cls(local, (), call=call)
        for receipt in receipts:
            address = receipt.get("endpoint", receipt["id"])
            host = {**receipt}
            host["call"] = (local.dispatch if receipt["id"] == "local" else
                            lambda method, params, address=address: fleet.call(address, method, params))
            fleet.hosts.append(host)
        return fleet

    @staticmethod
    def rpc(address, method, params):
        destination = endpoint(address["host"], address["port"]) if isinstance(address, dict) else endpoint(address, 58465)
        resolved = socket.getaddrinfo(destination["host"], destination["port"], type=socket.SOCK_STREAM)
        if not resolved or any(not tailnet_address(item[4][0]) for item in resolved):
            raise RPCError("approval_required", "La dirección del equipo no resuelve dentro de Tailscale")
        numeric = resolved[0][4][0]
        identifier = str(uuid.uuid4())
        with socket.create_connection((numeric, destination["port"]), timeout=4) as connection:
            connection.settimeout(20)
            connection.sendall(encode_frame({"id": identifier, "method": "mobile." + method, "params": params}))
            decoder = FrameDecoder()
            while True:
                chunk = connection.recv(65536)
                if not chunk:
                    raise ConnectionError()
                for response in decoder.feed(chunk):
                    if response.get("id") != identifier:
                        continue
                    if not response.get("ok"):
                        error = response.get("error", {})
                        raise RPCError(error.get("code", "host_inaccesible"), "El equipo no pudo completar la petición")
                    return response["result"]

    def plan(self):
        self.hosts = [{"id": "local", "label": "Este equipo", "call": self.local.dispatch}]
        seen = set()
        for peer in self.peers:
            address = endpoint(peer["host"], peer["port"]) if "host" in peer else peer["address"]
            identity = (address["host"], address["port"]) if isinstance(address, dict) else address
            if identity in seen:
                continue
            seen.add(identity)
            self.hosts.append({"id": peer.get("id", str(identity)), "endpoint": address,
                               "label": peer.get("name", peer.get("label", str(identity))),
                               "call": lambda method, params, address=address: self.call(address, method, params)})
        def prepare(host):
            try:
                if host["id"] == "local":
                    machine_id = self.local.machine_id
                else:
                    status = host["call"]("host.status", {})
                    if "relaunch.v1" not in status.get("capabilities", []):
                        raise RPCError("no_soportado", "El equipo no anuncia relaunch.v1")
                    machine_id = status["machine_id"]
                    if machine_id == self.local.machine_id:
                        raise RPCError("duplicado", "Este equipo ya está incluido como local")
                host["plan"] = host["call"]("relaunch.plan", {
                    "verb": "agent.relaunch", "scope": {"kind": "machine", "id": machine_id}})
            except Exception as error:
                host["error"] = getattr(error, "code", "host_inaccesible")
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(prepare, self.hosts))
        targets, excluded = [], []
        for host in self.hosts:
            if "error" in host:
                excluded.append({"label": host["label"], "cause": host["error"]})
                continue
            for target in host["plan"]["targets"]:
                targets.append({**target, "key": host["id"] + "|" + target["key"],
                                "label": host["label"] + " · " + target["label"]})
            excluded.extend({**item, "label": host["label"] + " · " + item["label"]}
                            for item in host["plan"]["excluded"])
        return {"operation_id": str(uuid.uuid4()), "verb": "agent.relaunch", "targets": targets,
                "excluded": excluded, "fleet": self}

    def operation(self, method):
        results, in_progress = [], False
        for host in self.hosts:
            if "plan" not in host:
                continue
            plan = host["plan"]
            params = {"operation_id": plan["operation_id"]}
            if method == "relaunch.apply":
                if "token" not in plan:
                    raise RPCError("token_no_valido", "Un recibo solo permite consultar, no volver a aplicar")
                params["token"] = plan["token"]
            try:
                if hasattr(self.local, "allowed") and not self.local.main(self.local.allowed):
                    raise RPCError("permisos", "El escritorio ya no permite esta operación")
                if method == "relaunch.apply" and host["id"] != "local" and hasattr(self.local, "machines"):
                    # A changed/deleted RPC route is not permission to send the
                    # frozen plan to a replacement host. Status remains read-only
                    # against the original receipt endpoint.
                    route = host["endpoint"]
                    if not any(machine["id"] == host["id"] and machine["host"] == route["host"]
                               and machine["port"] == route["port"] for machine in self.local.machines.snapshot()):
                        raise RPCError("generacion_cambiada", "El equipo configurado cambió después del plan")
                value = host["call"](method, params)
                results.extend({**item, "key": host["id"] + "|" + item["key"]} for item in value["results"])
                in_progress |= value["operation_state"] == "en_curso"
            except Exception as error:
                cause = getattr(error, "code", "host_inaccesible")
                unknown = cause in ("host_inaccesible", "internal_error", "timeout")
                in_progress |= unknown and bool(plan["targets"])
                results.extend({"key": host["id"] + "|" + item["key"],
                                "state": "planificado" if unknown else "necesita_usuario",
                                "cause": cause} for item in plan["targets"])
        return {"recovered": method == "relaunch.status", "operation_state": "en_curso" if in_progress else "terminada",
                "results": results}
