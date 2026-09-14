"""Behavioral admission, identity, ownership and phase tests for relaunch.v1."""

import copy
import json
from pathlib import Path
import tempfile
import unittest

from uniconnect.mobile_protocol import RPCError
from uniconnect.relaunch import RelaunchService
from uniconnect.relaunch_agents import RelaunchUnavailable


class Adapter:
    def __init__(self):
        self.calls = []

    def probe(self, candidate, verb):
        if candidate.get("excluded"):
            raise RelaunchUnavailable(candidate["excluded"])
        return {"key": candidate.get("key", "pane:1|gen:3"), "generation": 3, "effective_id": "current"}

    def execute(self, candidate, verb, proof, operation, changed, authorized):
        self.calls.append((candidate, proof))
        if verb == "agent.relaunch":
            changed({"state": "cerrando"})
            changed({"state": "reabriendo"})
            return {"state": "verificado", "effective_id": proof["effective_id"]}
        changed({"state": "reenganchando" if verb == "transport.reconnect" else "entregando"})
        return {"state": "verificado"}


class RelaunchTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-relaunch-test-")
        self.addCleanup(self.directory.cleanup)
        self.clock = [1000]
        self.jobs = []
        self.adapter = Adapter()
        self.service = RelaunchService(Path(self.directory.name), self.adapter, clock=lambda: self.clock[0],
                                      submit=lambda *args: self.jobs.append(args))
        self.allowed = [True]
        self.authorized = lambda: self.allowed[0]

    def plan(self, verb="agent.relaunch", candidates=None):
        return self.service.plan(verb, candidates or [{"label": "Proyecto · IA", "provider": "codex"}], "owner", self.authorized)

    def apply(self, plan, **kwargs):
        return self.service.apply(plan["operation_id"], kwargs.get("token", plan["token"]),
                                  kwargs.get("owner", "owner"), self.authorized)

    def test_plan_has_no_effects_deduplicates_and_includes_unknown_providers(self):
        plan = self.plan(candidates=[{"label": "A", "provider": "codex"}, {"label": "B", "provider": "codex"},
            {"label": "C", "provider": "other", "excluded": "no_soportado"}])
        self.assertEqual(len(plan["targets"]), 1)
        self.assertEqual([e["cause"] for e in plan["excluded"]], ["duplicado", "no_soportado"])
        self.assertEqual(self.jobs, [])
        self.assertEqual(self.adapter.calls, [])

    def test_nonblocking_apply_recovered_expired_token_and_per_verb_phases(self):
        for verb in ("agent.relaunch", "agent.continue", "transport.reconnect"):
            plan = self.plan(verb)
            result = self.apply(plan)
            self.assertEqual(result["operation_state"], "en_curso")
            self.assertFalse(result["recovered"])
            self.clock[0] += 121
            recovered = self.apply(plan)
            self.assertTrue(recovered["recovered"])
            self.assertEqual(recovered["operation_state"], "en_curso")
            job = self.jobs.pop(0)
            job[0](*job[1:])
            status = self.service.status(plan["operation_id"], "owner", self.authorized)
            self.assertEqual(status["operation_state"], "terminada")
            self.assertEqual(status["results"][0]["state"], "verificado")
        self.assertEqual(len(self.adapter.calls), 3)

    def test_expired_new_apply_wrong_token_owner_and_revocation_have_no_effect(self):
        plan = self.plan()
        for kwargs in ({"token": "x" * 32}, {"owner": "other"}):
            with self.assertRaises(RPCError) as error:
                self.apply(plan, **kwargs)
            self.assertEqual(error.exception.code, "token_no_valido")
        self.clock[0] += 120
        with self.assertRaises(RPCError) as error:
            self.apply(plan)
        self.assertEqual(error.exception.code, "token_caducado")
        self.assertEqual(self.jobs, [])
        plan = self.plan()
        self.apply(plan)
        self.allowed[0] = False
        with self.assertRaises(RPCError):
            self.apply(plan)
        with self.assertRaises(RPCError):
            self.service.status(plan["operation_id"], "owner", self.authorized)
        job = self.jobs.pop()
        job[0](*job[1:])
        self.assertEqual(self.adapter.calls, [])

    def test_status_does_not_disclose_to_other_device_and_restart_does_not_reexecute(self):
        plan = self.plan()
        self.apply(plan)
        with self.assertRaises(RPCError):
            self.service.status(plan["operation_id"], "other", self.authorized)
        new_service = RelaunchService(Path(self.directory.name), self.adapter, submit=lambda *a: self.fail("reexecuted"))
        result = new_service.apply(plan["operation_id"], plan["token"], "owner", self.authorized)
        self.assertTrue(result["recovered"])
        self.assertEqual(self.adapter.calls, [])

    def test_disk_failure_before_acceptance_never_schedules_process_work(self):
        plan = self.plan()
        self.service.writer = lambda *args: (_ for _ in ()).throw(OSError("disk full"))
        with self.assertRaises(OSError):
            self.apply(plan)
        self.assertEqual(self.jobs, [])

    def test_same_fixture_shapes_and_no_extra_window_after_plan(self):
        fixtures = Path(__file__).resolve().parents[2] / "contracts/relaunch-v1"
        request = json.loads((fixtures / "plan-request.json").read_text())
        workspace = {"id": request["scope"]["id"], "windows": [{"id": "one"}]}
        selection = RelaunchService.scope(request["scope"], "machine", [workspace])
        candidates = [{"label": r["id"], "provider": "codex"} for _, r in selection]
        plan = self.plan(request["verb"], candidates)
        workspace["windows"].append({"id": "new"})
        result = self.apply(plan)
        example = json.loads((fixtures / "apply-in-progress-response.json").read_text())
        self.assertEqual(set(result), set(example))
        self.assertEqual(len(result["results"]), 1)
        self.assertEqual(len(self.jobs), 1)
        for scope in ({"kind": "global", "id": "all"}, {"kind": "machine", "id": "other"}, None):
            with self.assertRaises(RPCError):
                RelaunchService.scope(scope, "machine", [workspace])

    def test_new_phase_cannot_undo_a_terminal_result(self):
        plan = self.plan()
        self.apply(plan)
        key = plan["targets"][0]["key"]
        self.service.update(plan["operation_id"], key, {"state": "omitido", "cause": "generacion_cambiada"})
        self.service.update(plan["operation_id"], key, {"state": "cerrando"})
        self.assertEqual(self.service.status(plan["operation_id"], "owner", self.authorized)["results"][0]["state"], "omitido")

    def test_concurrent_status_during_submission_never_starts_recovery(self):
        plan = self.plan()
        submitted = []
        def submit(*job):
            submitted.append(job)
            self.service.status(plan["operation_id"], "owner", self.authorized)
        self.service.submit = submit
        self.apply(plan)
        self.assertEqual(len(submitted), 1)
        self.assertEqual(submitted[0][0], self.service.execute)

    def test_temporarily_unreachable_recovery_can_later_reach_verified(self):
        plan = self.plan()
        self.apply(plan)
        self.service.running.clear()  # Simulate a new desktop, not a new apply.
        self.adapter.recover = lambda target, operation: (_ for _ in ()).throw(RelaunchUnavailable("host_inaccesible"))
        target = self.service.read(plan["operation_id"])["targets"][0]
        self.service.recover(plan["operation_id"], target, self.authorized)
        value = self.service.read(plan["operation_id"])["results"][0]
        self.assertEqual(value["state"], "planificado")
        self.assertEqual(value["cause"], "host_inaccesible")
        self.adapter.recover = lambda target, operation: {"state": "verificado", "effective_id": "current"}
        self.service.recover(plan["operation_id"], target, self.authorized)
        value = self.service.read(plan["operation_id"])["results"][0]
        self.assertEqual(value["state"], "verificado")
        self.assertNotIn("cause", value)
        self.assertEqual(self.adapter.calls, [])

    def test_closing_desktop_stops_observation_and_prevents_new_dispatch(self):
        closed = []
        self.adapter.close = lambda: closed.append(True)
        plan = self.plan()
        self.service.close()
        with self.assertRaises(RPCError):
            self.apply(plan)
        self.assertEqual(closed, [True])
        self.assertEqual(self.jobs, [])
        self.assertEqual(self.adapter.calls, [])
