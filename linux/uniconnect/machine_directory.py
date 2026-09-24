"""Explicit outgoing host inventory, matching Android's machines.v1 DTO.

A configured endpoint is NOT proof of live connectivity or authorization. It
contains no passwords and must never be derived from incoming access approvals.
"""

import json
import re
import threading
import uuid

from .mobile_access import tailnet_address
from .vault import atomic_write, private_read


def endpoint(host, port):
    host = str(host).strip().strip("[]").lower()
    try:
        port = int(port)
    except (ValueError, TypeError):
        raise ValueError("El puerto debe estar entre 1 y 65535") from None
    if not 1 <= port <= 65535 or not 1 <= len(host) <= 253:
        raise ValueError("Dirección o puerto de equipo no válidos")
    address = tailnet_address(host)
    if address:
        return {"host": address, "port": port}
    labels = host.split(".")
    if (":" in host or all(c in "0123456789." for c in host)
            or not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in labels)
            or not (len(labels) == 1 or (len(labels) >= 3 and host.endswith(".ts.net")))):
        raise ValueError("Usa una dirección Tailscale o un nombre MagicDNS del equipo")
    return {"host": host, "port": port}


class MachineDirectory:
    def __init__(self, root):
        self.path = root / "machines.v1.json"
        self.lock = threading.RLock()

    def snapshot(self):
        with self.lock:
            data = json.loads(private_read(self.path, maximum=65536)) if self.path.exists() else []
            if not isinstance(data, list) or len(data) > 128:
                raise ValueError("Directorio de equipos no válido")
            seen = set()
            for machine in data:
                if (not isinstance(machine.get("id"), str) or not machine["id"] or machine["id"] in seen
                        or not isinstance(machine.get("name"), str) or not 1 <= len(machine["name"]) <= 120):
                    raise ValueError("Directorio de equipos no válido")
                seen.add(machine["id"])
                machine.update(endpoint(machine["host"], machine["port"]))
            return data

    def save(self, name, host, port):
        destination = endpoint(host, port)
        name = "".join(c for c in str(name) if c.isprintable()).strip()
        if not 1 <= len(name) <= 120:
            raise ValueError("Escribe un nombre de equipo de hasta 120 caracteres")
        with self.lock:
            data = self.snapshot()
            old = next((m for m in data if (m["host"], m["port"]) == (destination["host"], destination["port"])), None)
            if old:
                old["name"] = name
            else:
                if len(data) >= 128:
                    raise ValueError("El directorio admite hasta 128 equipos")
                data.append({"id": str(uuid.uuid4()), "name": name, **destination})
            atomic_write(self.path, json.dumps(data).encode())
            return data

    def remove(self, identifier):
        with self.lock:
            data = [m for m in self.snapshot() if m["id"] != identifier]
            atomic_write(self.path, json.dumps(data).encode())
            return data
