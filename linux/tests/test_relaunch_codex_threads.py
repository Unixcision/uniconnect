"""Codex 0.166+ (10-11): ni rollout abierto ni cerrojo; la identidad sale de la tabla `threads`.

Medido en NOTBETTING con un Codex 0.166 desechable: su TUI arranca `codex app-server` como hijos,
solo tiene abiertos sus SQLite, sigue escribiendo el rollout (lo da `threads.rollout_path`) y su
pie dice «← for agents · ? for shortcuts», con un enlace OSC 8 en la pancarta de actualización.
"""

import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest

from uniconnect.relaunch_worker import TargetWorker, Unavailable
from uniconnect.resume_catalog import AgentResumeCatalog

THREAD = "01a1c680-b7ac-7b03-9499-ca586de58648"


class CodexThreadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-codex-threads-")
        self.root = Path(self.directory.name)
        self.proc, self.home, self.work = self.root / "proc", self.root / "home", self.root / "work"
        (self.home / ".codex").mkdir(parents=True)
        self.work.mkdir()
        (self.proc).mkdir()
        (self.proc / "stat").write_text("cpu 1 2 3\nbtime 1794330000\n")
        self.worker = TargetWorker({"session": "fixture", "socket": "fixture", "provider": "codex",
                                    "catalog": AgentResumeCatalog().providers}, proc=self.proc)
        self.ticks = os.sysconf("SC_CLK_TCK")
        self.database = self.home / ".codex" / "state_5.sqlite"
        connection = sqlite3.connect(self.database)
        connection.execute("CREATE TABLE threads (id TEXT, cwd TEXT, created_at INTEGER, updated_at INTEGER, "
                           "created_at_ms INTEGER, updated_at_ms INTEGER, originator TEXT, archived INTEGER, "
                           "thread_source TEXT, rollout_path TEXT)")
        connection.commit()
        connection.close()

    def tearDown(self):
        self.directory.cleanup()

    def row(self, identifier, created_ms, updated_ms, *, originator="codex-tui", source="user", archived=0, cwd=None):
        connection = sqlite3.connect(self.database)
        connection.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?)",
                           (identifier, cwd or str(self.work), created_ms // 1000, updated_ms // 1000, created_ms,
                            updated_ms, originator, archived, source, "/r/rollout-x-" + identifier + ".jsonl"))
        connection.commit()
        connection.close()

    def process(self, pid, argv, start_s, parent=1):
        path = self.proc / str(pid)
        path.mkdir()
        (path / "environ").write_bytes(b"HOME=" + str(self.home).encode() + b"\0")
        ticks = int((start_s - 1794330000) * self.ticks)
        (path / "stat").write_text("%d (x) S %d %d 0 0 %d" % (pid, parent, pid, pid) + " 0" * 13 + " %d 0 0" % ticks)
        (path / "cmdline").write_bytes("\0".join(argv).encode() + b"\0")
        (path / "task" / str(pid)).mkdir(parents=True)
        (path / "task" / str(pid) / "children").write_text("")
        (path / "cwd").symlink_to(self.work)
        (path / "exe").symlink_to("/bin/true")
        return self.worker.process(pid)

    def test_the_newest_tui_thread_created_after_it_started_is_its_own(self):
        codex = self.process(10, ["/root/.local/bin/codex", "--yolo"], 1794331670)
        self.row("viejo", 1794331000000, 1794331100000)              # Antes de que arrancara.
        self.row("subagente", 1794331690000, 1794331800000, source="subagent")
        self.row("archivado", 1794331690000, 1794331800000, archived=1)
        self.row(THREAD, 1794331686834, 1794331701324)
        thread = self.worker.codex_thread(codex)
        self.assertEqual(thread["id"], THREAD)
        self.assertTrue(thread["rollout_path"].endswith(THREAD + ".jsonl"))
        self.row("empate", 1794331690000, 1794331701324)
        self.assertIsNone(self.worker.codex_thread(codex))  # Dos igual de recientes: no se adivina.

    def test_another_live_tui_in_the_same_folder_could_own_it(self):
        codex = self.process(10, ["/root/.local/bin/codex", "--yolo"], 1794331670)
        self.row(THREAD, 1794331686834, 1794331701324)
        self.process(20, ["/x/codex", "app-server"], 1794331600)       # Un subcomando de fondo no cuenta.
        self.assertEqual(self.worker.codex_thread(codex)["id"], THREAD)
        self.process(30, ["/root/.local/bin/codex"], 1794331600)        # Otro TUI que ya corría ahí.
        self.assertIsNone(self.worker.codex_thread(codex))

    def test_app_server_children_are_not_the_window_agent(self):
        self.assertTrue(TargetWorker.codex_background(["/r/bin/codex", "app-server"]))
        self.assertFalse(TargetWorker.codex_background(["/root/.local/bin/codex", "--yolo"]))
        self.assertFalse(TargetWorker.codex_background(["codex", "resume", THREAD, "--", "app-server"]))

    def test_codex_0_166_footer_and_osc_links_still_prove_an_empty_composer(self):
        placeholder = "\x1b[1m›\x1b[0m \x1b[2mAsk Codex to do anything\x1b[0m"
        banner = "│ \x1b]8;;https://x\x1b\\https://x\x1b]8;;\x1b\\ │"
        styled = [banner, "", placeholder, "", "  \x1b[38;5;223mGPT-6-Astra medium\x1b[39m · /tmp/w · Responder ok",
                  "  \x1b[1m←\x1b[0m for agents · \x1b[1m?\x1b[0m for shortcuts      ⚠ 1 warning"]
        plain = ["│ https://x │", "", "› Ask Codex to do anything", "", "  GPT-6-Astra medium · /tmp/w · Responder ok",
                 "  ← for agents · ? for shortcuts      ⚠ 1 warning"]
        self.worker.tmux = lambda *args: "\n".join(styled if "-e" in args else plain)
        self.worker.codex_activity = lambda lines: {}
        self.worker.require_empty_composer({"pane": {"pane": "%1"}})
        plain[2] = "› borrador escrito"
        styled[2] = "\x1b[1m›\x1b[0m borrador escrito"
        with self.assertRaises(Unavailable) as error:
            self.worker.require_empty_composer({"pane": {"pane": "%1"}})
        self.assertEqual(error.exception.cause, "dialogo_desconocido")


class CodexUpdateDialogTests(unittest.TestCase):
    """coordNov 10-11: «Skip» por su texto, solo ese diálogo y solo el Codex que se acaba de reabrir."""

    SCREEN = ["  Update available · 0.166.0 → 0.167.0",
              "  Release notes: https://github.com/openai/codex/releases/latest",
              "{0} 1. Update now (runs `sh -c 's=$(curl -fsSL https://chatgpt.com/codex/install.sh) && CODEX_NON_INTERACTIVE=",
              "{1} 2. Skip",
              "{2} 3. Skip until next version",
              "  enter continue · esc skip"]

    def setUp(self):
        self.worker = TargetWorker({"session": "fixture", "socket": "fixture", "provider": "codex",
                                    "catalog": AgentResumeCatalog().providers})
        self.worker.answered, self.keys, self.cursor = [], [], 0
        self.agent = {"pid": 7, "argv": ["/x/codex", "resume", THREAD, "--yolo"]}
        self.worker.descendants = lambda pid: {7: self.agent, 8: {"pid": 8, "argv": ["/x/codex", "app-server"]}}

        def tmux(*args):
            if args[0] == "send-keys":
                self.keys.append(args[-1])
                self.cursor = min(2, self.cursor + 1) if args[-1] == "Down" else max(0, self.cursor - 1) if args[-1] == "Up" else self.cursor
                return ""
            marks = ["›" if index == self.cursor else " " for index in range(3)]
            return "\n".join(line.format(*marks) for line in self.SCREEN)
        self.worker.tmux = tmux
        self.proof = {"pane": {"pane": "%1"}, "effective_id": THREAD}

    def test_skip_is_chosen_by_its_text_and_recorded(self):
        self.assertTrue(self.worker.answer_codex_update(self.proof, {"pid": 1}))
        self.assertEqual(self.keys, ["Down", "Enter"])  # Del «Update now» marcado a «Skip», y solo entonces Intro.
        self.assertEqual(self.worker.answered, ["codex_update_skip"])

    def test_anything_else_is_left_to_a_person(self):
        self.agent = {"pid": 7, "argv": ["/x/codex", "resume", "otra-conversacion"]}
        self.assertFalse(self.worker.answer_codex_update(self.proof, {"pid": 1}))
        self.agent = {"pid": 7, "argv": ["/x/codex", "resume", THREAD]}
        original = list(self.SCREEN)
        self.SCREEN = [line.replace("2. Skip", "2. Skip and remember") for line in original]
        self.assertFalse(self.worker.answer_codex_update(self.proof, {"pid": 1}))
        # Un aviso ya contestado que sigue arriba en pantalla, con la IA debajo: no es el diálogo vivo.
        self.SCREEN = original + ["› Responde solo con la palabra: ok", "• ok", "/exit"]
        self.assertFalse(self.worker.answer_codex_update(self.proof, {"pid": 1}))
        self.assertEqual(self.keys, [])  # No se ha tecleado nada.
        self.worker.tmux = lambda *args: "› Ask Codex to do anything"
        self.assertFalse(self.worker.answer_codex_update(self.proof, {"pid": 1}))


class CodexOpenElsewhereTests(unittest.TestCase):
    """Codex 0.166+: su servidor compartido tarda en soltar al cliente cerrado; «r» unos segundos después."""

    SCREEN = "› Responde solo con la palabra: ok\n  🔒  This conversation is open in another app\n" \
             "      Close it there and press R to continue here.\n   r retry   f fork   esc/^c/q exit   ^t transcript"

    def test_retries_with_r_after_a_while_at_most_four_times_and_only_for_its_codex(self):
        worker = TargetWorker({"session": "fixture", "socket": "fixture", "provider": "codex",
                               "catalog": AgentResumeCatalog().providers})
        worker.answered, keys, now = [], [], [100.0]
        worker.clock = lambda: now[0]
        agent = {"pid": 7, "argv": ["/x/codex", "resume", THREAD]}
        worker.descendants = lambda pid: {7: agent}
        worker.tmux = lambda *args: keys.append(args[-1]) or "" if args[0] == "send-keys" else self.SCREEN
        proof = {"pane": {"pane": "%1"}, "effective_id": THREAD}
        for moment in (100, 101, 103.5, 105, 108, 112, 116, 120, 200):
            now[0] = moment
            worker.retry_codex_open_elsewhere(proof, {"pid": 1})
        self.assertEqual(keys, ["r", "r", "r", "r"])  # Tras 3 s, luego cada 4 s, y no más de 4.
        self.assertEqual(worker.answered, ["codex_retry_open_elsewhere"])
        other = TargetWorker({"session": "fixture", "socket": "fixture", "provider": "codex",
                              "catalog": AgentResumeCatalog().providers})
        other.answered, other.clock = [], (lambda: 999.0)
        other.descendants = lambda pid: {7: {"pid": 7, "argv": ["/x/codex", "resume", "otra"]}}
        other.tmux = worker.tmux
        keys.clear()
        other.open_elsewhere_since = 0
        other.retry_codex_open_elsewhere(proof, {"pid": 1})
        self.assertEqual(keys, [])  # No es el Codex que reabrimos: nada.


if __name__ == "__main__":
    unittest.main()
