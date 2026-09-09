"""Durable favourite/order changes shared by desktop actions and mobile RPC."""


class WorkspaceArrangement:
    def __init__(self, store):
        self.store = store

    @staticmethod
    def ordered(records):
        # Projection only: opening a list must not mutate or save the model.
        return sorted(records, key=lambda record: not bool(record.get("pinned")))

    @staticmethod
    def pane_ids(workspace):
        present = list(dict.fromkeys(w.get("paneId", "main") for w in workspace["windows"]))
        saved = workspace.get("paneOrder", [])
        return list(dict.fromkeys([p for p in saved if p in present] + present))

    def update(self, workspace_id, terminal_id=None, **changes):
        if not isinstance(workspace_id, str) or not workspace_id:
            raise ValueError("Indica una caja existente")
        workspace = next((w for w in self.store.workspaces if w["id"] == workspace_id), None)
        if workspace is None:
            raise ValueError("No se encontró la caja")
        items = self.store.workspaces
        record = workspace
        if terminal_id is not None:
            if not isinstance(terminal_id, str) or not terminal_id:
                raise ValueError("Indica una ventana existente")
            items = workspace["windows"]
            record = next((w for w in items if w["id"] == terminal_id), None)
            if record is None:
                raise ValueError("No se encontró la ventana")
        if set(changes) - {"is_pinned", "position"}:
            raise ValueError("Cambio de favoritos u orden no válido")
        if "is_pinned" in changes and type(changes["is_pinned"]) is not bool:
            raise ValueError("El favorito debe ser verdadero o falso")
        if "position" in changes and type(changes["position"]) is not int:
            raise ValueError("La posición debe ser un número entero")
        if not changes:
            return False
        original = list(items)
        pin_present, old_pin = "pinned" in record, record.get("pinned")
        pane_present, old_panes = "paneOrder" in workspace, workspace.get("paneOrder")
        panes = self.pane_ids(workspace)
        try:
            if "is_pinned" in changes:
                record["pinned"] = changes["is_pinned"]
            ordered = self.ordered(items)
            if "position" in changes:
                group = [r for r in ordered if bool(r.get("pinned")) == bool(record.get("pinned")) and r is not record]
                group.insert(max(0, min(changes["position"], len(group))), record)
                other = [r for r in ordered if bool(r.get("pinned")) != bool(record.get("pinned"))]
                ordered = group + other if record.get("pinned") else other + group
            if ordered == original and bool(old_pin) == bool(record.get("pinned")):
                if not pin_present:
                    record.pop("pinned", None)
                return False
            items[:] = ordered
            if terminal_id is not None:
                # List ordering is independent from left/right (or top/bottom)
                # geometry, including after the next app restart.
                workspace["paneOrder"] = panes
            self.store.save()
        except Exception:
            items[:] = original
            if pin_present:
                record["pinned"] = old_pin
            else:
                record.pop("pinned", None)
            if pane_present:
                workspace["paneOrder"] = old_panes
            else:
                workspace.pop("paneOrder", None)
            raise
        return True
