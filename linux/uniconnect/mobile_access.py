"""Locally approved, observed Tailscale peers; network JSON is never identity."""

import ipaddress
import json
import threading
import time
import uuid

from .vault import atomic_write, private_read


def tailnet_address(value):
    try:
        address = ipaddress.ip_address(value)
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            address = address.ipv4_mapped
        network = ipaddress.ip_network("100.64.0.0/10" if address.version == 4 else "fd7a:115c:a1e0::/48")
        return str(address) if address in network else None
    except (ValueError, TypeError):
        return None


class MobileAccess:
    def __init__(self, root, *, clock=time.time, writer=atomic_write):
        self.path = root / "mobile-access.json"
        self.clock, self.writer = clock, writer
        self.lock = threading.RLock()
        self.pending, self.rejected, self.approved = {}, {}, {}
        self.machine_id = str(uuid.uuid4())
        self.on_change = lambda: None
        self.on_revoke = lambda address: None
        if self.path.exists():
            data = json.loads(private_read(self.path, maximum=65536))
            if data.get("version") != 1 or not isinstance(data.get("approved"), list) or len(data["approved"]) > 128:
                raise ValueError("Permisos remotos no válidos")
            self.machine_id = str(uuid.UUID(data["machine_id"]))
            for peer in data["approved"]:
                address = tailnet_address(peer["address"])
                if not address or address != peer["address"]:
                    raise ValueError("Permiso remoto no válido")
                self.approved[address] = peer
        else:
            self._save(self.approved)

    def _save(self, approved):
        self.writer(self.path, json.dumps({"version": 1, "machine_id": self.machine_id,
                                         "approved": list(approved.values())}, ensure_ascii=False).encode())

    def snapshot(self):
        with self.lock:
            self._expire()
            return list(self.approved.values()), list(self.pending.values())

    def _expire(self):
        now = self.clock()
        self.pending = {key: value for key, value in self.pending.items() if value["expires_at"] > now}
        self.rejected = {key: value for key, value in self.rejected.items() if value > now}

    def authorize(self, observed_address, label=""):
        address = tailnet_address(observed_address)
        if not address:
            return False
        changed = False
        with self.lock:
            self._expire()
            if address in self.approved:
                return True
            if address not in self.rejected and address not in self.pending and len(self.pending) < 8:
                label = "".join(c for c in str(label) if c.isprintable()).strip()[:80] or address
                self.pending[address] = {"address": address, "label": label, "expires_at": self.clock() + 120}
                changed = True
        if changed:
            self.on_change()
        return False

    def is_approved(self, observed_address):
        address = tailnet_address(observed_address)
        with self.lock:
            return bool(address and address in self.approved)

    def approve(self, address):
        with self.lock:
            self._expire()
            peer = self.pending.get(address)
            if not peer or len(self.approved) >= 128:
                return False
            approved = dict(self.approved)
            approved[address] = {"address": address, "label": peer["label"], "approved_at": self.clock()}
            self._save(approved)  # No transient access if persistence fails.
            self.approved = approved
            self.pending.pop(address, None)
        self.on_change()
        return True

    def reject(self, address):
        with self.lock:
            self.pending.pop(address, None)
            self.rejected[address] = self.clock() + 120
            self._bound_rejections()
        self.on_change()

    def revoke(self, address):
        with self.lock:
            self.approved.pop(address, None)
            self.pending.pop(address, None)
            self.rejected[address] = self.clock() + 120
            self._bound_rejections()
            # Revocation takes effect immediately even if its durable write fails.
            self.on_revoke(address)
            self._save(self.approved)
        self.on_change()

    def _bound_rejections(self):
        if len(self.rejected) > 128:
            oldest = min(self.rejected, key=self.rejected.get)
            self.rejected.pop(oldest, None)
