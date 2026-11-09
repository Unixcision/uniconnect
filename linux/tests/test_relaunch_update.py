"""relaunch-v1 (09-11): «Actualizar Claude» y lo que aprendió el reciclado a mano de 47 Claude.

Fichas de otro arranque, conversaciones compartidas, login, monitores, borradores, coste,
lanzador estable y `claude update` una vez por instalación. Todo contra un /proc y un HOME falsos.
"""

import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

from uniconnect.relaunch_worker import TargetWorker, Unavailable
from uniconnect.resume_catalog import AgentResumeCatalog

SESSION = "473ed1de-4397-45ef-b00b-6b17fd7382b0"
WRAPPER = ("source /root/.claude/shell-snapshots/snapshot-bash-1.sh 2>/dev/null || true && shopt -u extglob 2>/dev/null "
           "|| true && { \\builtin unalias -- 'unsetenv'; \\builtin unset -f -- 'unsetenv'; } >/dev/null 2>&1 || true && "
           "eval 'tail -n0 -F /tmp/claude-0/x/tasks/a.output | grep --line-buffered HOLA' < /dev/null && pwd -P >| /tmp/claude-50ca-cwd")
RULE = "\x1b[38;5;244m" + "─" * 40 + "\x1b[39m"


class Fixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-update-")
        self.root = Path(self.directory.name)
        self.proc, self.home = self.root / "proc", self.root / "home"
        self.config = self.home / ".claude"
        (self.config / "sessions").mkdir(parents=True)
        self.worker = TargetWorker({"session": "fixture", "socket": "fixture", "provider": "claude", "window_id": "w-1",
                                    "catalog": AgentResumeCatalog().providers}, proc=self.proc)
        self.worker.STATE = self.root / "state"

    def tearDown(self):
        self.directory.cleanup()

    def process(self, pid, argv, start="100", parent=1):
        path = self.proc / str(pid)
        path.mkdir(parents=True, exist_ok=True)
        (path / "environ").write_bytes(b"HOME=" + str(self.home).encode() + b"\0PATH=" + str(self.root / "bin").encode() + b"\0")
        (path / "stat").write_text("%d (x) S %d %d 0 0 %d" % (pid, parent, pid, pid) + " 0" * 13 + " " + start + " 0 0")
        (path / "cmdline").write_bytes("\0".join(argv).encode() + b"\0")
        (path / "task" / str(pid)).mkdir(parents=True, exist_ok=True)
        (path / "task" / str(pid) / "children").write_text("")
        for name, target in (("cwd", "/"), ("exe", "/bin/true")):
            if not (path / name).is_symlink():
                (path / name).symlink_to(target)
        return {"pid": pid, "parent": parent, "group": pid, "foreground": pid, "start": start, "argv": argv,
                "cwd": "/", "executable": "/bin/true"}

    def ficha(self, pid, **values):
        data = {"pid": pid, "sessionId": SESSION, "status": "idle", **values}
        (self.config / "sessions" / ("%d.json" % pid)).write_text(json.dumps(data))


class FichaTests(Fixture):
    def test_a_ficha_from_another_start_with_the_pid_reused_is_not_its_own(self):
        process = self.process(4242, ["claude"], start="129006")
        self.ficha(4242, procStart="129006")
        self.assertEqual(self.worker.claude_ficha(process)["sessionId"], SESSION)
        self.ficha(4242, procStart="555")  # putillaz decía ser la conversación de anastasiia.
        self.assertIsNone(self.worker.claude_ficha(process))
        with self.assertRaises(Unavailable) as error:
            self.worker.native_id("claude", process, "", {})
        self.assertEqual(error.exception.cause, "identidad_ambigua")

    def test_older_fichas_are_checked_by_started_at_and_one_without_either_cannot_contradict(self):
        process = self.process(4242, ["claude"], start="100")
        bounds = TargetWorker.process_birth_bounds(process)
        self.ficha(4242, startedAt=int(bounds[0] * 1000) + 500)
        self.assertIsNotNone(self.worker.claude_ficha(process))
        self.ficha(4242, startedAt=int((bounds[0] - 3600) * 1000))
        self.assertIsNone(self.worker.claude_ficha(process))
        self.ficha(4242)
        self.assertIsNotNone(self.worker.claude_ficha(process))

    def test_two_live_claudes_on_the_same_conversation_are_shared(self):
        mine = self.process(4242, ["claude"], start="1")
        self.ficha(4242, procStart="1")
        self.assertFalse(self.worker.claude_shared(mine, SESSION))
        self.process(5151, ["/root/.local/share/claude/versions/2.1.321"], start="2")
        self.ficha(5151, procStart="2")  # XUNIS: claudebets y xunis_stats.
        self.assertTrue(self.worker.claude_shared(mine, SESSION))
        self.ficha(5151, procStart="9")  # Una ficha vieja de un PID reutilizado no cuenta.
        self.assertFalse(self.worker.claude_shared(mine, SESSION))


class MonitorTests(Fixture):
    def test_orders_are_extracted_saved_with_their_scratchpad_files_and_never_secrets_of_others(self):
        self.assertEqual(TargetWorker.bash_wrapper_order(["/bin/bash", "-c", WRAPPER]),
                         "tail -n0 -F /tmp/claude-0/x/tasks/a.output | grep --line-buffered HOLA")
        scratch = Path("/tmp/claude-%d/uc-update-test-%d" % (os.geteuid(), os.getpid()))
        scratch.mkdir(parents=True, exist_ok=True)
        self.addCleanup(lambda: (scratch / "vigia.sh").unlink(missing_ok=True) or scratch.rmdir())
        (scratch / "vigia.sh").write_text("echo vigía\n")
        order = "bash %s/vigia.sh >> /tmp/fuera.log" % scratch
        path = Path(self.worker.save_monitors([({"pid": 1}, order), ({"pid": 2}, "sleep 9")]))
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        text = path.read_text()
        self.assertIn(order, text)
        self.assertIn("sleep 9", text)
        copied = next(path.with_suffix("").rglob("vigia.sh"))
        self.assertEqual(copied.read_text(), "echo vigía\n")
        self.assertIsNone(self.worker.save_monitors([]))

    def test_only_direct_wrapper_children_count(self):
        claude = self.process(10, ["claude"])
        self.process(11, ["/bin/bash", "-c", WRAPPER], parent=10)
        self.process(12, ["npm", "exec", "resend-mcp"], parent=10)
        self.process(13, ["tail", "-F", "x"], parent=11)
        (self.proc / "10/task/10/children").write_text("11 12")
        (self.proc / "11/task/11/children").write_text("13")
        work = self.worker.claude_background_work(claude["pid"])
        self.assertEqual([process["pid"] for process, _ in work], [11])


class ComposerTests(Fixture):
    def screen(self, *composer, cursor=None):
        lines = ["● hecho", "", RULE, *composer, RULE, "  root@host:~ | Haiku 5.5 | effort:medium"]
        row = 3 + (len(composer) - 1 if cursor is None else cursor)
        self.worker.tmux = lambda *args: str(row) if args[0] == "display-message" else "\n".join(lines)

    def test_empty_suggestion_and_drafts(self):
        self.screen("\x1b[39m❯\xa0")
        self.assertEqual(self.worker.claude_composer("%1"), "")
        self.screen('\x1b[39m❯\xa0\x1b[2mTry\x1b[0m \x1b[2m"fix typecheck errors"\x1b[0m')
        self.assertEqual(self.worker.claude_composer("%1"), "")  # El gris atenuado es una sugerencia.
        self.screen("\x1b[39m❯\xa0hola esto es un borrador")
        self.assertEqual(self.worker.claude_composer("%1"), "hola esto es un borrador")
        self.screen("❯ línea uno del pegado", "  línea dos", "    tres con sangría")
        self.assertEqual(self.worker.claude_composer("%1"), "línea uno del pegado\nlínea dos\n  tres con sangría")
        self.worker.tmux = lambda *args: "5" if args[0] == "display-message" else "Do you trust the files?\n❯ 1. Yes"
        self.assertIsNone(self.worker.claude_composer("%1"))  # Sin el bloque entre rayas no hay compositor.


class CostAndOptionsTests(Fixture):
    def test_context_tokens_come_from_the_last_usage_read_from_the_end(self):
        process = self.process(4242, ["claude"])
        project = self.config / "projects" / "-root"
        project.mkdir(parents=True)
        rows = [{"type": "user", "message": {"content": "x"}},
                {"type": "assistant", "message": {"usage": {"input_tokens": 1, "cache_read_input_tokens": 2}}},
                {"type": "assistant", "message": {"usage": {"input_tokens": 5, "cache_creation_input_tokens": 100,
                                                            "cache_read_input_tokens": 411895, "output_tokens": 9}}},
                {"type": "user", "message": {"content": "y" * 300000}}]
        (project / (SESSION + ".jsonl")).write_text("\n".join(json.dumps(row) for row in rows) + "\n")
        self.assertEqual(self.worker.claude_context_tokens(process, SESSION), 412000)
        self.assertIsNone(self.worker.claude_context_tokens(process, "otra"))

    def test_model_and_effort_replace_what_it_had_and_bad_values_are_refused(self):
        argv = ["/h/.local/bin/claude", "--resume", SESSION, "--model", "opus", "--dangerously-skip-permissions"]
        self.assertEqual(TargetWorker.with_options(argv, {"model": "fable[1m]", "effort": "medium"}),
                         ["/h/.local/bin/claude", "--resume", SESSION, "--dangerously-skip-permissions",
                          "--model", "fable[1m]", "--effort", "medium"])
        self.assertEqual(TargetWorker.with_options(argv, {}), argv)  # «Igual que estaba».
        for options in ({"model": "Opus; rm"}, {"effort": "turbo"}, {"modelo": "x"}, ["fable"]):
            with self.subTest(options=options), self.assertRaises(Unavailable) as error:
                TargetWorker.with_options(argv, options)
            self.assertEqual(error.exception.cause, "opciones_no_validas")
        resumed = TargetWorker.resume_arguments("claude", argv + ["--effort", "high"], SESSION, self.worker.request["catalog"])
        self.assertIn("--effort", resumed)  # Relanzar no pierde el effort con que corría.

    def test_reopen_uses_the_stable_launcher_by_absolute_path(self):
        process = self.process(4242, ["/root/.local/share/claude/versions/2.1.281", "--model", "haiku"])
        process["executable"] = "/root/.local/share/claude/versions/2.1.281"
        self.assertEqual(self.worker.launch_executable("claude", process), "/root/.local/share/claude/versions/2.1.281")
        launcher = self.home / ".local/bin/claude"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("#!/bin/sh\n")
        launcher.chmod(0o755)
        # NOTBETTING: root no tiene ~/.local/bin en el PATH; la ruta absoluta del lanzador sí vale.
        self.assertEqual(self.worker.launch_executable("claude", process), str(launcher))

    def test_the_plan_only_data_never_makes_a_target_look_like_another(self):
        plan = {"key": "k", "generation": 1, "background": 2, "draft": False, "message": True,
                "context_tokens": 10, "installation": {"installed": "2.1.281"}}
        later = dict(plan, background=0, context_tokens=99, installation={"installed": "2.1.321"})
        self.assertTrue(TargetWorker.same_target(later, plan))
        self.assertFalse(TargetWorker.same_target(dict(later, generation=2), plan))


class MessageTests(Fixture):
    TEXTS = json.loads((Path(__file__).resolve().parents[2] / "contracts/relaunch-v1/mensajes.json").read_text())

    def message(self, verb, work, status):
        self.worker.request.update(verb=verb, messages=self.TEXTS, updated_to="2.1.321")
        self.worker.claude_work, self.worker.claude_status = work, status
        self.worker.claude_work_file = "/root/.local/state/uniconnect/relaunch-v1/monitores/w-1.txt"
        return self.worker.relaunch_message()

    def test_only_with_monitors_or_while_working_and_with_the_exact_texts(self):
        self.assertIsNone(self.message("agent.relaunch", [], "idle"))  # Reabrir no gasta cupo; el mensaje sí.
        text = self.message("agent.update", [({}, "tail -F x"), ({}, "sleep 1")], "busy")
        self.assertTrue(text.startswith("UniConnect te ha reiniciado para actualizar Claude Code a 2.1.321. "
                                        "Al cerrar se pararon tus 2 monitores"))
        self.assertIn("monitores/w-1.txt", text)
        self.assertTrue(text.endswith(self.TEXTS["anadido_cortado"]))
        self.assertEqual(self.message("agent.relaunch", [], "busy"),
                         self.TEXTS["solo_cortado"].replace("{motivo}", self.TEXTS["motivo_relanzar"]))


class UpdateTests(Fixture):
    def launcher(self, script):
        versions = self.home / ".local/share/claude/versions"
        versions.mkdir(parents=True)
        for version in ("2.1.281", "2.1.321"):
            (versions / version).write_text("#!/bin/sh\n")
            (versions / version).chmod(0o755)
        launcher = self.home / ".local/bin/claude"
        launcher.parent.mkdir(parents=True)
        (launcher.parent / "claude-real").write_text("#!/bin/sh\n" + script)
        (launcher.parent / "claude-real").chmod(0o755)
        launcher.symlink_to(versions / "2.1.281")
        return launcher

    def update(self, launcher, script):
        real = str(launcher.parent / "claude-real")
        self.worker.request["launcher"] = str(launcher)
        self.worker.run = lambda argv, **kwargs: subprocess.run([real, *argv[1:]], **kwargs)
        return self.worker.update_installation()

    def test_update_once_reports_from_to_and_a_failure_does_not_pretend(self):
        launcher = self.launcher("")
        switch = 'ln -sfn "%s" "%s"\n' % (self.home / ".local/share/claude/versions/2.1.321", launcher)
        (launcher.parent / "claude-real").write_text("#!/bin/sh\n[ \"$1\" = update ] && " + switch)
        self.assertEqual(self.update(launcher, ""), {"state": "actualizado", "from": "2.1.281", "to": "2.1.321"})
        self.assertEqual(self.update(launcher, ""), {"state": "ya_al_dia", "from": "2.1.321", "to": "2.1.321"})
        (launcher.parent / "claude-real").write_text("#!/bin/sh\nexit 1\n")
        self.assertEqual(self.update(launcher, "")["state"], "fallida")

    def test_only_an_absolute_claude_launcher_is_updated(self):
        for launcher in ("claude", "/usr/bin/python3", str(self.home / "nada/claude")):
            self.worker.request["launcher"] = launcher
            with self.subTest(launcher=launcher), self.assertRaises(Unavailable) as error:
                self.worker.update_installation()
            self.assertEqual(error.exception.cause, "binario_no_encontrado")


class UpdateAdapter:
    """Lo mínimo del adaptador para el orquestador: plan por objetivo, `update` por instalación y cierre."""

    def __init__(self, updates):
        self.updates, self.updated, self.executed = list(updates), [], []

    def probe(self, candidate, verb, options=None):
        if candidate.get("excluded"):
            from uniconnect.relaunch_agents import RelaunchUnavailable
            raise RelaunchUnavailable(candidate["excluded"])
        return {"key": candidate["key"], "generation": 1, "effective_id": "e-" + candidate["key"],
                "background": candidate.get("background", 0), "draft": False, "message": candidate.get("message", False),
                "context_tokens": candidate.get("tokens"),
                "installation": {"launcher": candidate.get("launcher", "/root/.local/bin/claude"),
                                 "version": "2.1.281", "installed": "2.1.321"}}

    def update(self, candidate, proof):
        self.updated.append((candidate.get("connection"), proof["installation"]["launcher"]))
        return self.updates.pop(0)

    def execute(self, candidate, verb, proof, operation, changed, authorized, **extra):
        self.executed.append((candidate["key"], extra))
        changed({"state": "cerrando"})
        return {"state": "verificado", "effective_id": proof["effective_id"], "version": extra.get("updated_to"),
                "message_sent": proof["message"], "draft_restored": False, "background_saved": proof["background"]}


class ServiceUpdateTests(unittest.TestCase):
    def setUp(self):
        from uniconnect.relaunch import RelaunchService
        self.directory = tempfile.TemporaryDirectory(prefix="uc-update-service-")
        self.addCleanup(self.directory.cleanup)
        self.jobs = []
        self.adapter = UpdateAdapter([{"state": "actualizado", "from": "2.1.281", "to": "2.1.321"},
                                      {"state": "fallida", "from": "2.1.300", "to": None}])
        self.service = RelaunchService(Path(self.directory.name), self.adapter, clock=lambda: 1000,
                                       submit=lambda function, *args, **kwargs: self.jobs.append((function, args, kwargs)))

    def run_jobs(self):
        while self.jobs:
            function, args, kwargs = self.jobs.pop(0)
            function(*args, **kwargs)

    def candidates(self):
        return [{"label": "NB · a", "provider": "claude", "key": "a", "connection": "ssh root@nb", "message": True,
                 "tokens": 412000, "background": 3},
                {"label": "NB · b", "provider": "claude", "key": "b", "connection": "ssh root@nb", "tokens": 380000},
                {"label": "DESA · c", "provider": "claude", "key": "c", "connection": "ssh ec2@desa", "message": True,
                 "tokens": 1000},
                {"label": "NB · codex", "provider": "codex", "key": "x", "excluded": "proveedor_no_soportado"}]

    def test_options_belong_to_update_only_and_are_validated(self):
        from uniconnect.mobile_protocol import RPCError
        for verb, options in (("agent.relaunch", {}), ("agent.relaunch", {"model": "opus"}),
                              ("agent.update", {"model": "Opus Grande"}), ("agent.update", {"effort": "turbo"}),
                              ("agent.update", {"temperature": 1})):
            with self.subTest(verb=verb, options=options), self.assertRaises(RPCError) as error:
                self.service.plan(verb, self.candidates(), "owner", lambda: True, options=options)
            self.assertEqual(error.exception.code, "opciones_no_validas")

    def test_plan_shows_cost_monitors_versions_and_excludes_other_providers(self):
        plan = self.service.plan("agent.update", self.candidates(), "owner", lambda: True,
                                 options={"model": "fable[1m]", "effort": "medium"})
        self.assertEqual(plan["options"], {"model": "fable[1m]", "effort": "medium"})
        self.assertEqual(plan["estimated_tokens"], 413000)  # Solo los que recibirán mensaje.
        first = plan["targets"][0]
        self.assertEqual((first["background"], first["message"], first["context_tokens"], first["version"],
                          first["installed"]), (3, True, 412000, "2.1.281", "2.1.321"))
        self.assertEqual(plan["excluded"], [{"label": "NB · codex", "cause": "proveedor_no_soportado"}])

    def test_update_runs_once_per_installation_before_closing_and_a_failure_closes_nothing(self):
        plan = self.service.plan("agent.update", self.candidates(), "owner", lambda: True, options={})
        self.service.apply(plan["operation_id"], plan["token"], "owner", lambda: True)
        self.assertEqual(self.adapter.executed, [])  # Nada se cierra antes de su `claude update`.
        self.run_jobs()
        self.assertEqual(self.adapter.updated, [("ssh root@nb", "/root/.local/bin/claude"),
                                                ("ssh ec2@desa", "/root/.local/bin/claude")])
        self.assertEqual([key for key, _ in self.adapter.executed], ["a", "b"])
        self.assertEqual(self.adapter.executed[0][1], {"options": {}, "updated_to": "2.1.321"})
        status = self.service.status(plan["operation_id"], "owner", lambda: True)
        self.assertEqual([(item["host"], item["state"]) for item in status["updates"]],
                         [("ssh", "actualizado"), ("ssh", "fallida")])
        results = {item["key"]: item for item in status["results"]}
        self.assertEqual((results["a"]["state"], results["a"]["version"], results["a"]["message_sent"]),
                         ("verificado", "2.1.321", True))
        self.assertEqual((results["c"]["state"], results["c"]["cause"]), ("omitido", "actualizacion_fallida"))
        self.assertEqual(status["operation_state"], "terminada")


class TrustTests(Fixture):
    """Dani (09-11): «Yes, I trust this folder» por su texto, solo para la conversación que ya corría allí."""

    DIALOG = ("Do you trust the files in this folder?\n\n/root/uc-prueba\n\n"
              "❯ 1. No, exit\n  2. Yes, I trust this folder\n\nEnter to confirm · Esc to cancel")

    def setUp(self):
        super().setUp()
        self.sent, self.screens = [], [self.DIALOG, "❯ "]
        self.proof = {"pane": {"pane": "%1"}, "effective_id": SESSION}
        self.worker.reopen_cwd = "/root/uc-prueba"
        self.asking = {"pid": 7, "cwd": "/root/uc-prueba", "argv": ["/root/.local/bin/claude", "--resume", SESSION]}
        self.worker.descendants = lambda pid: {7: self.asking}

        def tmux(*args):
            if args[0] == "send-keys":
                self.sent.append(args[-1])
                self.screens.pop(0)
                return ""
            if args[0] == "display-message":
                return "3"
            return self.screens[0]
        self.worker.tmux = tmux

    def test_answers_by_its_text_only_for_the_same_conversation_and_folder(self):
        self.assertTrue(self.worker.answer_trust(self.proof, {"pid": 1}))
        self.assertEqual(self.sent, ["2"])  # La opción que dice «Yes, I trust this folder», no la marcada.
        self.screens = ["❯ "]
        self.assertFalse(self.worker.answer_trust(self.proof, {"pid": 1}))  # Sin diálogo no se teclea nada.

    def test_any_other_case_is_left_to_a_person(self):
        for change in ({"cwd": "/root/otra"}, {"argv": ["/root/.local/bin/claude", "--resume", "otra-conversacion"]}):
            self.asking = {"pid": 7, "cwd": "/root/uc-prueba",
                           "argv": ["/root/.local/bin/claude", "--resume", SESSION], **change}
            self.screens = [self.DIALOG]
            with self.subTest(change=change), self.assertRaises(Unavailable) as error:
                self.worker.answer_trust(self.proof, {"pid": 1})
            self.assertEqual(error.exception.cause, "confianza_carpeta")
        self.asking = {"pid": 7, "cwd": "/root/uc-prueba", "argv": ["/root/.local/bin/claude", "--resume", SESSION]}
        self.screens = ["Do you trust the files in this folder?\n❯ Yes, I trust this folder\n  No, exit"]
        with self.assertRaises(Unavailable):
            self.worker.answer_trust(self.proof, {"pid": 1})  # Sin número que lo nombre, nunca por posición.
        self.assertEqual(self.sent, [])


if __name__ == "__main__":
    unittest.main()
