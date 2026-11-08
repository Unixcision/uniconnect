"""log.v1 en Linux: formato del contrato, niveles, depuración en caliente con apagado a las 24 h,
rotación 5 MiB × 5, permisos, saneado de `detail` y las líneas del relanzado."""

import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from contracts_dir import contract
from uniconnect.event_log import DEBUG_SECONDS, EventLog
from uniconnect.relaunch import RelaunchService

REQUIRED = ("ts", "level", "area", "event", "platform", "version")


class EventLogTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="uc-log-")
        self.path = Path(self.folder.name) / "logs" / "uniconnect.jsonl"
        self.now = [1_790_000_000.0]
        self.settings, self.saves = {}, []
        self.log = EventLog(self.path, version="0.1.0+abcdef1234", settings=lambda: self.settings,
                            save=lambda: self.saves.append(dict(self.settings)), clock=lambda: self.now[0])

    def tearDown(self):
        self.folder.cleanup()

    def lines(self, path=None):
        target = path or self.path
        return [json.loads(line) for line in target.read_text().splitlines()] if target.exists() else []

    def test_lines_have_the_contract_shape_and_private_permissions(self):
        self.assertTrue(self.log.info("relaunch", "relaunch.plan", op="op-1", window="w1",
                                      detail={"verb": "agent.relaunch", "targets": 2}))
        line, = self.lines()
        self.assertEqual(line["ts"], "2026-09-21T14:13:20.000Z")
        self.assertEqual({key: line[key] for key in REQUIRED[1:]},
                         {"level": "info", "area": "relaunch", "event": "relaunch.plan", "platform": "linux",
                          "version": "0.1.0+abcdef1234"})
        self.assertEqual((line["op"], line["window"], line["detail"]), ("op-1", "w1", {"verb": "agent.relaunch", "targets": 2}))
        self.assertEqual(oct(self.path.parent.stat().st_mode & 0o777), "0o700")
        self.assertEqual(oct(self.path.stat().st_mode & 0o777), "0o600")

    def test_the_contract_example_reads_with_the_same_fields_and_values(self):
        example = contract("log-v1", "ejemplo.jsonl").read_text().splitlines()
        for raw in example:
            line = json.loads(raw)
            with self.subTest(event=line["event"]):
                self.assertTrue(all(key in line for key in REQUIRED))
                self.assertIn(line["level"], ("debug", "info", "warn", "error"))
                self.assertTrue(self.log.write(line["level"] if line["level"] != "debug" else "info", line["area"],
                                               line["event"], workspace=line.get("workspace"), window=line.get("window"),
                                               op=line.get("op"), detail=line.get("detail")))

    def test_debug_only_when_enabled_and_it_switches_itself_off_after_24_hours(self):
        self.assertFalse(self.log.debug("activity", "activity.changed", detail={"from": "idle", "to": "working"}))
        reply = self.log.set_debug(True)
        self.assertEqual(reply, {"enabled": True, "until": "2026-09-22T14:13:20.000Z"})
        self.assertEqual(self.saves[-1]["log_debug"], True)
        self.assertTrue(self.log.debug("activity", "activity.changed", detail={"from": "idle", "to": "working"}))
        self.now[0] += DEBUG_SECONDS + 1
        self.assertFalse(self.log.debug("activity", "activity.changed"))
        events = [(line["event"], line.get("detail")) for line in self.lines()]
        self.assertEqual(events, [("log.debug_on", None), ("activity.changed", {"from": "idle", "to": "working"}),
                                  ("log.debug_off", {"reason": "timeout"})])
        self.assertEqual((self.settings["log_debug"], self.settings["log_debug_until"]), (False, None))
        self.assertEqual(self.log.set_debug(False), {"enabled": False, "until": None})  # Ya apagado: sin línea.
        self.assertEqual(len(self.lines()), 3)

    def test_rotates_in_cascade_and_never_keeps_more_than_five_files(self):
        small = EventLog(self.path, version="v", clock=lambda: self.now[0], max_bytes=400)
        for number in range(40):
            small.info("ui", "ui.action_failed", detail={"action": "reconnect", "cause": "x" * 20, "n": number})
        names = sorted(item.name for item in self.path.parent.iterdir())
        self.assertEqual(names, ["uniconnect.jsonl", "uniconnect.jsonl.1", "uniconnect.jsonl.2",
                                 "uniconnect.jsonl.3", "uniconnect.jsonl.4"])
        self.assertTrue(all(item.stat().st_size <= 400 for item in self.path.parent.iterdir()))
        newest = self.lines()[-1]["detail"]["n"]
        self.assertEqual(newest, 39)

    def test_a_failed_rotation_leaves_its_own_line_and_keeps_writing(self):
        small = EventLog(self.path, version="v", clock=lambda: self.now[0], max_bytes=200)
        small.info("ui", "ui.action_failed", detail={"cause": "y" * 150})
        # La copia más vieja es un directorio con algo dentro: borrarla falla y la rotación con ella.
        (self.path.parent / "uniconnect.jsonl.4").mkdir()
        (self.path.parent / "uniconnect.jsonl.4" / "ocupado").write_text("x")
        self.assertTrue(small.info("ui", "ui.action_failed", detail={"cause": "z"}))
        events = [line["event"] for line in self.lines()]
        self.assertEqual(events[-2:], ["log.rotate_failed", "ui.action_failed"])

    def test_detail_keeps_ids_and_codes_but_never_free_text(self):
        self.log.warn("ui", "ui.action_failed", detail={
            "action": "relaunch_window", "cause": "no_soportado", "count": 3, "ok": True,
            "screen": "Do you want to proceed?\n❯ 1. Yes", "token": "a" * 200, "Bad-Key": "x",
            "options": ["--model", "--chrome"]})
        detail = self.lines()[0]["detail"]
        self.assertEqual(detail["action"], "relaunch_window")
        self.assertEqual(detail["options"], ["--model", "--chrome"])
        self.assertEqual(detail["screen"], {"length": 32})  # Texto de pantalla: solo su longitud.
        self.assertEqual(detail["token"], {"length": 200})
        self.assertNotIn("Bad-Key", detail)

    def test_never_raises_and_rejects_unknown_areas_levels_or_events(self):
        blocked = EventLog(Path(self.folder.name) / "fichero" / "log.jsonl", version="v")
        (Path(self.folder.name) / "fichero").write_text("no soy un directorio")
        self.assertFalse(blocked.info("ui", "ui.action_failed"))
        self.assertFalse(self.log.info("otra", "otra.cosa"))
        self.assertFalse(self.log.write("fatal", "ui", "ui.action_failed"))
        self.assertFalse(self.log.info("ui", "SinPuntos"))
        self.assertEqual(self.lines(), [])


class RelaunchLinesTests(unittest.TestCase):
    class Capture:
        def __init__(self):
            self.lines = []

        def write(self, level, area, event, **fields):
            self.lines.append((level, event, fields.get("window"), fields.get("detail")))

        def info(self, area, event, **fields):
            self.write("info", area, event, **fields)

        def warn(self, area, event, **fields):
            self.write("warn", area, event, **fields)

        def error(self, area, event, **fields):
            self.write("error", area, event, **fields)

    def test_each_escalation_step_and_dropped_option_leaves_a_line(self):
        capture = self.Capture()
        service = RelaunchService.__new__(RelaunchService)
        service.log = capture
        value = {"targets": [{"proof": {"key": "k"}, "record": {"id": "w1", "agent": "claude"}, "workspace_id": "b1"}]}
        service.log_result("op", value, {"key": "k", "state": "verificado", "escalation": "recreate_session",
                                         "dropped_options": ["--raro"]})
        service.log_result("op", value, {"key": "k", "state": "necesita_usuario", "cause": "confianza_carpeta"})
        self.assertEqual([(level, event) for level, event, _, _ in capture.lines], [
            ("warn", "relaunch.exit_timeout"), ("warn", "relaunch.kill_session"), ("info", "relaunch.session_recreated"),
            ("warn", "relaunch.option_dropped"), ("info", "relaunch.resumed"), ("error", "relaunch.failed")])
        self.assertTrue(all(window == "w1" for _, _, window, _ in capture.lines))
        self.assertEqual(capture.lines[-1][3], {"state": "necesita_usuario", "cause": "confianza_carpeta"})


class ControlSocketTests(unittest.TestCase):
    def test_log_debug_goes_through_the_app_and_validates_its_argument(self):
        from uniconnect.control import ControlServer
        calls = []
        window = SimpleNamespace(locked=True, event_log=SimpleNamespace(set_debug=lambda value: calls.append(value) or
                                                                         {"enabled": value, "until": None}))
        server = ControlServer.__new__(ControlServer)
        server.window = window
        self.assertEqual(server.dispatch({"command": "log.debug", "enabled": True}), {"enabled": True, "until": None})
        with self.assertRaises(ValueError):
            server.dispatch({"command": "log.debug", "enabled": "sí"})
        self.assertEqual(calls, [True])


if __name__ == "__main__":
    unittest.main()
