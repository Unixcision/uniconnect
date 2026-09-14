"""Private desktop receipts; reopening a receipt only queries, never reapplies."""

import copy
import json
import time
import uuid

from .vault import atomic_write, private_read


class RelaunchHistory:
    def __init__(self, root, *, clock=time.time):
        self.root, self.clock = root, clock

    def remember(self, plan):
        identifier = str(uuid.UUID(plan["operation_id"]))
        receipt = {key: copy.deepcopy(plan[key]) for key in ("operation_id", "verb", "targets", "excluded")}
        receipt["created_at"] = self.clock()
        if "fleet" in plan:
            receipt["hosts"] = [{"id": host["id"], "label": host["label"], "endpoint": host.get("endpoint", host["id"]),
                                  "plan": {key: copy.deepcopy(host["plan"][key])
                                           for key in ("operation_id", "targets", "excluded")}}
                                 for host in plan["fleet"].hosts if "plan" in host]
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Persist before dispatch, so a lost apply response remains discoverable.
        # Tokens, credentials, argv and provider content are deliberately absent.
        atomic_write(self.root / (identifier + ".json"), json.dumps(receipt).encode())

    def recent(self):
        paths = sorted(self.root.glob("*.json"), key=lambda path: path.lstat().st_mtime, reverse=True)[:40]
        return [json.loads(private_read(path, maximum=1024 * 1024)) for path in paths]
