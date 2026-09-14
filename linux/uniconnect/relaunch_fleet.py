"""Client fan-out: 'global' freezes machine plans, never invents a server scope."""

from concurrent.futures import ThreadPoolExecutor
import socket
import uuid

from .mobile_access import tailnet_address
from .mobile_protocol import FrameDecoder, RPCError, encode_frame


class RelaunchFleet:
    def __init__(self, local, peers, *, call=None):
        self.local, self.peers = local, tuple(peers)
        self.call = call or self.rpc
        self.hosts = []

    @staticmethod
    def rpc(address, method, params):
        if not tailnet_address(address):
            raise RPCError("approval_required", "El equipo no es una dirección autorizada de Tailscale")
        identifier = str(uuid.uuid4())
        with socket.create_connection((address, 58465), timeout=4) as connection:
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
            address = peer["address"]
            if address in seen:
                continue
            seen.add(address)
            self.hosts.append({"id": address, "label": peer.get("label", address),
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
                params["token"] = plan["token"]
            try:
                value = host["call"](method, params)
                results.extend({**item, "key": host["id"] + "|" + item["key"]} for item in value["results"])
                in_progress |= value["operation_state"] == "en_curso"
            except Exception as error:
                results.extend({"key": host["id"] + "|" + item["key"], "state": "necesita_usuario",
                                "cause": getattr(error, "code", "host_inaccesible")} for item in plan["targets"])
        return {"recovered": method == "relaunch.status", "operation_state": "en_curso" if in_progress else "terminada",
                "results": results}
