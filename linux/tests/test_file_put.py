"""file_put.v1 en el host Linux: saneado, reserva, trozos, verificación, caducidad y salto SSH."""

import base64
import datetime
import hashlib
import tempfile
import types
import unicodedata
import unittest
from pathlib import Path

from uniconnect.file_put import FilePutStore, RemoteInbox, numbered_names, sanitize_name
from uniconnect.mobile_protocol import RPCError
from uniconnect.mobile_rpc import MobileRPC
from uniconnect.transport import SSHCommand, TransportError

TODAY = datetime.date(2026, 9, 9)


def sha(data):
    return hashlib.sha256(data).hexdigest()


class NameTests(unittest.TestCase):
    def test_paths_control_characters_and_shell_syntax_are_removed(self):
        cases = {
            "foto.jpg": "foto.jpg",
            "../../etc/passwd": "passwd",
            "C:\\Users\\dani\\informe.pdf": "informe.pdf",
            "con\ttab\x00y\nsalto.txt": "contabysalto.txt",
            "  .oculto  ": "oculto",
            "..": "archivo",
            "": "archivo",
            "\x07\x1b[31m": "_31m",
            "ñandú café.PNG": "ñandú café.PNG",
            "IMG_20260909-123456.jpg": "IMG_20260909-123456.jpg",
            "informe final.": "informe final",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(sanitize_name(raw), expected)
        hostile = sanitize_name("$(rm -rf ~)`id`;a|b&c>d<e'f\"g.png")
        self.assertTrue(hostile.endswith(".png"))
        self.assertFalse(set(hostile) & set("$()`;|&<>'\"~"))
        with self.assertRaises(RPCError) as error:
            sanitize_name(42)
        self.assertEqual(error.exception.code, "invalid_params")

    def test_length_is_bounded_and_extension_survives(self):
        long = sanitize_name("a" * 300 + ".tar.gz")
        self.assertEqual(len(long), 120)
        self.assertTrue(long.endswith(".gz"))
        wide = sanitize_name("漢" * 300 + ".txt")
        self.assertLessEqual(len(wide.encode("utf-8")), 200)
        self.assertTrue(wide.endswith(".txt"))
        for value in (long, wide, sanitize_name(".gz"), sanitize_name("x" * 200)):
            self.assertTrue(value)
            self.assertFalse(any(unicodedata.category(c)[0] == "C" for c in value))
            self.assertFalse(value.startswith("."))

    def test_numbered_names_keep_extension(self):
        names = numbered_names("foto.jpg")
        self.assertEqual([next(names) for _ in range(3)], ["foto.jpg", "foto-2.jpg", "foto-3.jpg"])
        self.assertEqual(list(numbered_names("sinext"))[:2], ["sinext", "sinext-2"])


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-fileput-")
        self.root = Path(self.directory.name) / "Entrada"
        self.now = 1000.0
        self.store = FilePutStore(self.root, clock=lambda: self.now, today=lambda: TODAY, chunk_bytes=4)
        self.box = {"workspace_id": "caja", "kind": "local", "credential_id": None}

    def tearDown(self):
        self.directory.cleanup()

    @property
    def day(self):
        return self.root / "20260909"

    def send(self, owner, name, data, *, chunk=4):
        ticket = self.store.begin(owner, self.box, name, len(data))
        for index, offset in enumerate(range(0, len(data), chunk)):
            self.store.chunk(owner, ticket["transfer_id"], index, data[offset:offset + chunk])
        return ticket["transfer_id"]

    def test_begin_reserves_part_and_commit_publishes_verified_file(self):
        data = b"hola mundo"
        ticket = self.store.begin("movil", self.box, "saludo.txt", len(data))
        self.assertEqual(ticket["chunk_bytes"], 4)
        self.assertTrue((self.day / "saludo.txt.part").exists())
        self.assertEqual(self.store.lookup("movil", ticket["transfer_id"]), self.box)
        received = [self.store.chunk("movil", ticket["transfer_id"], index, data[offset:offset + 4])["received_bytes"]
                    for index, offset in enumerate(range(0, len(data), 4))]
        self.assertEqual(received, [4, 8, 10])
        result = self.store.commit("movil", ticket["transfer_id"], sha(data).upper())
        self.assertEqual(result, {"path": str(self.day / "saludo.txt"), "location": "host"})
        self.assertEqual((self.day / "saludo.txt").read_bytes(), data)
        self.assertEqual(sorted(p.name for p in self.day.iterdir()), ["saludo.txt"])
        with self.assertRaises(RPCError) as error:
            self.store.commit("movil", ticket["transfer_id"], sha(data))
        self.assertEqual(error.exception.code, "not_found")

    def test_zero_byte_file_commits_without_chunks(self):
        ticket = self.store.begin("movil", self.box, "vacio.txt", 0)
        result = self.store.commit("movil", ticket["transfer_id"], sha(b""))
        self.assertEqual(Path(result["path"]).read_bytes(), b"")

    def test_wrong_sha_discards_file_and_part(self):
        transfer = self.send("movil", "datos.bin", b"0123456789")
        with self.assertRaises(RPCError) as error:
            self.store.commit("movil", transfer, sha(b"otro"))
        self.assertEqual(error.exception.code, "io_failed")
        self.assertEqual(list(self.day.iterdir()), [])
        with self.assertRaises(RPCError) as error:
            self.store.abort("movil", transfer)
        self.assertEqual(error.exception.code, "not_found")

    def test_out_of_order_duplicate_or_incomplete_chunks_are_invalid_params(self):
        ticket = self.store.begin("movil", self.box, "orden.bin", 8)
        transfer = ticket["transfer_id"]
        with self.assertRaises(RPCError) as error:
            self.store.chunk("movil", transfer, 1, b"abcd")
        self.assertEqual(error.exception.code, "invalid_params")
        self.store.chunk("movil", transfer, 0, b"abcd")
        with self.assertRaises(RPCError) as error:
            self.store.chunk("movil", transfer, 0, b"abcd")
        self.assertEqual(error.exception.code, "invalid_params")
        with self.assertRaises(RPCError) as error:
            self.store.commit("movil", transfer, sha(b"abcd"))
        self.assertEqual(error.exception.code, "invalid_params")
        for bad in ((True, b"ab"), (-1, b"ab"), (1, b""), (1, b"toolong")):
            with self.subTest(bad=bad), self.assertRaises(RPCError) as error:
                self.store.chunk("movil", transfer, *bad)
            self.assertEqual(error.exception.code, "invalid_params")
        self.store.chunk("movil", transfer, 1, b"efgh")
        with self.assertRaises(RPCError) as error:
            self.store.commit("movil", transfer, "zz")
        self.assertEqual(error.exception.code, "invalid_params")
        self.assertEqual(Path(self.store.commit("movil", transfer, sha(b"abcdefgh"))["path"]).read_bytes(), b"abcdefgh")

    def test_size_limits(self):
        with self.assertRaises(RPCError) as error:
            self.store.begin("movil", self.box, "grande.iso", self.store.max_size + 1)
        self.assertEqual(error.exception.code, "too_large")
        for size in (-1, "10", 2.5, True):
            with self.subTest(size=size), self.assertRaises(RPCError) as error:
                self.store.begin("movil", self.box, "x", size)
            self.assertEqual(error.exception.code, "invalid_params")
        transfer = self.store.begin("movil", self.box, "corto.bin", 6)["transfer_id"]
        self.store.chunk("movil", transfer, 0, b"abcd")
        with self.assertRaises(RPCError) as error:
            self.store.chunk("movil", transfer, 1, b"efgh")
        self.assertEqual(error.exception.code, "too_large")
        self.assertEqual(list(self.day.iterdir()), [])

    def test_transfer_expires_after_ten_minutes_without_chunks(self):
        transfer = self.store.begin("movil", self.box, "lento.bin", 8)["transfer_id"]
        self.now += 599
        self.store.chunk("movil", transfer, 0, b"abcd")
        self.now += 599
        self.assertTrue((self.day / "lento.bin.part").exists())
        self.now += 1
        with self.assertRaises(RPCError) as error:
            self.store.chunk("movil", transfer, 1, b"efgh")
        self.assertEqual(error.exception.code, "not_found")
        self.assertEqual(list(self.day.iterdir()), [])
        other = self.store.begin("movil", self.box, "otro.bin", 0)["transfer_id"]
        self.now += 600
        self.assertEqual(self.store.expire(), 1)
        with self.assertRaises(RPCError):
            self.store.lookup("movil", other)

    def test_concurrent_and_repeated_uploads_never_overwrite(self):
        (self.day).mkdir(parents=True)
        (self.day / "foto.jpg").write_bytes(b"anterior")
        first = self.send("a", "foto.jpg", b"uno")
        second = self.send("b", "foto.jpg", b"dos")
        self.assertEqual(sorted(p.name for p in self.day.iterdir()),
                         ["foto-2.jpg.part", "foto-3.jpg.part", "foto.jpg"])
        (self.day / "foto-2.jpg").write_bytes(b"colado")  # Aparece fuera de UniConnect antes del commit.
        paths = [Path(self.store.commit(owner, transfer, sha(data))["path"])
                 for owner, transfer, data in (("a", first, b"uno"), ("b", second, b"dos"))]
        self.assertEqual([p.name for p in paths], ["foto-4.jpg", "foto-3.jpg"])
        self.assertEqual([p.read_bytes() for p in paths], [b"uno", b"dos"])
        self.assertEqual((self.day / "foto.jpg").read_bytes(), b"anterior")
        self.assertEqual((self.day / "foto-2.jpg").read_bytes(), b"colado")
        self.assertFalse(list(self.day.glob("*.part")))

    def test_other_owner_gets_not_found(self):
        transfer = self.send("movil", "privado.txt", b"secreto")
        for action in (lambda: self.store.lookup("otro", transfer),
                       lambda: self.store.chunk("otro", transfer, 1, b"x"),
                       lambda: self.store.commit("otro", transfer, sha(b"secreto")),
                       lambda: self.store.abort("otro", transfer),
                       lambda: self.store.abort("movil", "inventado"),
                       lambda: self.store.abort("movil", None)):
            with self.assertRaises(RPCError) as error:
                action()
            self.assertEqual(error.exception.code, "not_found")
        self.store.discard("otro", transfer)  # Silencioso y sin efecto sobre otro dueño.
        self.assertTrue((self.day / "privado.txt.part").exists())
        self.assertEqual(Path(self.store.commit("movil", transfer, sha(b"secreto"))["path"]).read_bytes(), b"secreto")

    def test_remote_copy_failure_keeps_host_path_with_readable_error(self):
        transfer = self.send("movil", "informe.pdf", b"%PDF-1.4")
        def failing(path, name):
            self.assertEqual((path.name, name), ("informe.pdf", "informe.pdf"))
            raise TransportError("connection_timeout")
        result = self.store.commit("movil", transfer, sha(b"%PDF-1.4"), remote_copy=failing)
        self.assertEqual(result["location"], "host")
        self.assertEqual(result["path"], str(self.day / "informe.pdf"))
        self.assertEqual(result["remote_error"], "El servidor no respondió a tiempo")
        self.assertNotIn("remote_path", result)
        self.assertEqual((self.day / "informe.pdf").read_bytes(), b"%PDF-1.4")
        transfer = self.send("movil", "informe.pdf", b"%PDF-1.5")
        result = self.store.commit("movil", transfer, sha(b"%PDF-1.5"),
                                   remote_copy=lambda path, name: "/home/u/uniconnect-entrada/" + name)
        self.assertEqual(result, {"path": str(self.day / "informe-2.pdf"), "location": "remote",
                                  "remote_path": "/home/u/uniconnect-entrada/informe-2.pdf"})

    def test_abort_disconnect_and_limits(self):
        transfer = self.send("movil", "cancelado.bin", b"1234")
        self.assertEqual(self.store.abort("movil", transfer), {})
        self.assertEqual(list(self.day.iterdir()), [])
        transfers = [self.store.begin("movil", self.box, f"n{i}.bin", 4)["transfer_id"] for i in range(4)]
        with self.assertRaises(RPCError) as error:
            self.store.begin("movil", self.box, "n5.bin", 4)
        self.assertEqual(error.exception.code, "busy")
        self.store.begin("otro", self.box, "n5.bin", 4)
        self.store.disconnected("movil")
        self.assertEqual([p.name for p in self.day.iterdir()], ["n5.bin.part"])
        for transfer in transfers:
            with self.assertRaises(RPCError):
                self.store.lookup("movil", transfer)

    def test_scheduled_sweep_deletes_the_part_without_further_traffic(self):
        timers = []
        def timer(interval, callback):
            handle = types.SimpleNamespace(interval=interval, callback=callback, cancelled=False)
            handle.cancel = lambda: setattr(handle, "cancelled", True)
            timers.append(handle)
            return handle
        store = FilePutStore(self.root, clock=lambda: self.now, today=lambda: TODAY, timer=timer)
        transfer = store.begin("movil", self.box, "abandonado.bin", 8)["transfer_id"]
        store.begin("movil", self.box, "segundo.bin", 8)
        self.assertEqual([t.interval for t in timers], [60])  # Un solo barrido para todas.
        self.now += 60
        timers[0].callback()
        self.assertTrue((self.day / "abandonado.bin.part").exists())
        self.assertEqual(len(timers), 2)  # Sigue habiendo transferencias: se reprograma.
        self.now += 539
        store.chunk("movil", transfer, 0, b"abcd")  # La actividad del mismo dispositivo la conserva.
        self.now += 1  # "segundo.bin" cumple los 600 s sin trozos; nadie llama al store.
        timers[1].callback()
        self.assertEqual(sorted(p.name for p in self.day.iterdir()), ["abandonado.bin.part"])
        self.assertEqual(len(timers), 3)
        self.now += 600
        timers[2].callback()  # Sin ningún RPC ni desconexión posterior.
        self.assertEqual(list(self.day.iterdir()), [])
        self.assertEqual(len(timers), 3)  # Sin transferencias no hay barrido pendiente.
        store.begin("movil", self.box, "vivo.bin", 8)
        self.assertEqual(len(timers), 4)
        store.close()
        self.assertTrue(timers[3].cancelled)
        self.assertEqual(list(self.day.iterdir()), [])
        with self.assertRaises(RPCError) as error:
            store.begin("movil", self.box, "tarde.bin", 8)
        self.assertEqual(error.exception.code, "busy")

    def test_real_daemon_timer_expires_off_thread(self):
        handles = []
        def timer(interval, callback):
            handle = FilePutStore.daemon_timer(interval, callback)
            handles.append(handle)
            return handle
        store = FilePutStore(self.root, clock=lambda: self.now, today=lambda: TODAY, sweep_interval=0.01, timer=timer)
        store.begin("movil", self.box, "abandonado.bin", 8)
        self.assertTrue(handles[0].daemon)
        self.now += 600
        handles[0].join(5)
        self.assertEqual(list(self.day.iterdir()), [])
        self.assertEqual(len(handles), 1)
        store.close()


class RemoteInboxTests(unittest.TestCase):
    def test_copy_creates_remote_directory_then_puts_with_exact_name(self):
        scripts, puts = [], []
        def transport(command, **_):
            def run(script, **options):
                scripts.append((command, script, options))
                return types.SimpleNamespace(stdout="Last login: hoy\nUC_DIR\t/home/dani/uniconnect-entrada\n")
            return types.SimpleNamespace(run=run)
        class Transfer:
            def __init__(self, command, *, timeout):
                puts.append((command, timeout))
            def put(self, local_path, directory, name):
                puts.append((str(local_path), directory, name))
                return directory + "/" + name
        command = SSHCommand.parse("ssh -p 2222 dani@example.com")
        inbox = RemoteInbox(transport_factory=transport, transfer_factory=Transfer, budget=42, clock=lambda: 0.0)
        self.assertEqual(inbox.copy(command, Path("/tmp/x/foto.jpg"), "foto.jpg"), "/home/dani/uniconnect-entrada/foto.jpg")
        self.assertIs(scripts[0][0], command)
        self.assertIn("mkdir -p -- \"$HOME/uniconnect-entrada\"", scripts[0][1])
        self.assertEqual(scripts[0][2], {"timeout": 42})
        self.assertEqual(puts, [(command, 42 - RemoteInbox.CLOSE_MARGIN),
                                ("/tmp/x/foto.jpg", "/home/dani/uniconnect-entrada", "foto.jpg")])

    def test_preparation_transfer_and_close_share_one_hundred_second_budget(self):
        now, calls = [1000.0], []
        def transport(command, **_):
            def run(script, *, timeout, **options):
                calls.append(("run", timeout))
                now[0] += 30
                return types.SimpleNamespace(stdout="UC_DIR\t/home/dani/uniconnect-entrada\n")
            return types.SimpleNamespace(run=run)
        class Transfer:
            def __init__(self, command, *, timeout):
                calls.append(("sftp", timeout))
            def put(self, local_path, directory, name):
                return directory + "/" + name
        inbox = RemoteInbox(transport_factory=transport, transfer_factory=Transfer, clock=lambda: now[0])
        inbox.copy(SSHCommand.parse("ssh dani@example.com"), Path("/tmp/x/a.bin"), "a.bin")
        self.assertEqual(calls, [("run", 100.0), ("sftp", 100.0 - 30 - RemoteInbox.CLOSE_MARGIN)])

    def test_exhausted_budget_answers_host_before_the_phone_gives_up(self):
        with tempfile.TemporaryDirectory(prefix="uc-fileput-budget-") as directory:
            now = [5000.0]
            store = FilePutStore(Path(directory), clock=lambda: now[0], today=lambda: TODAY)
            for slow_prepare, slow_transfer in ((95, 0), (30, None)):
                def transport(command, **_):
                    def run(script, *, timeout, **options):
                        now[0] += min(slow_prepare, timeout)
                        return types.SimpleNamespace(stdout="UC_DIR\t/home/dani/uniconnect-entrada\n")
                    return types.SimpleNamespace(run=run)
                class Transfer:
                    def __init__(self, command, *, timeout):
                        self.timeout = timeout
                    def put(self, local_path, directory, name):
                        now[0] += self.timeout  # El SFTP consume todo su plazo y lo anuncia.
                        raise TransportError("upload_timeout")
                inbox = RemoteInbox(transport_factory=transport, transfer_factory=Transfer, clock=lambda: now[0])
                command = SSHCommand.parse("ssh dani@example.com")
                transfer = store.begin("movil", {"workspace_id": "ssh"}, "lento.bin", 4)["transfer_id"]
                store.chunk("movil", transfer, 0, b"abcd")
                started = now[0]
                result = store.commit("movil", transfer, sha(b"abcd"),
                                      remote_copy=lambda path, name: inbox.copy(command, path, name))
                with self.subTest(slow_prepare=slow_prepare):
                    self.assertLessEqual(now[0] - started, 100)  # Antes de los 120 s del móvil.
                    self.assertEqual(result["location"], "host")
                    self.assertEqual(result["remote_error"], "La copia al servidor tardó demasiado y se canceló")
                    self.assertTrue(Path(result["path"]).exists())
            store.close()

    def test_copy_fails_when_the_directory_cannot_be_resolved(self):
        transport = lambda command, **_: types.SimpleNamespace(run=lambda *a, **k: types.SimpleNamespace(stdout=""))
        inbox = RemoteInbox(transport_factory=transport, transfer_factory=lambda *a, **k: self.fail("sin put"))
        with self.assertRaises(TransportError) as error:
            inbox.copy(SSHCommand.parse("ssh dani@example.com"), Path("/tmp/x"), "x")
        self.assertEqual(error.exception.code, "remote_command_failed")

    def test_describe_is_spanish_and_bounded(self):
        self.assertEqual(RemoteInbox.describe(TransportError("upload_timeout")),
                         "La copia al servidor tardó demasiado y se canceló")
        self.assertEqual(RemoteInbox.describe(TransportError("remote_command_failed", "mkdir: permiso\n denegado")),
                         "El servidor rechazó la orden: mkdir: permiso denegado")
        self.assertEqual(RemoteInbox.describe(TransportError("sshpass_missing")),
                         "Falta sshpass en el equipo para la contraseña guardada")
        self.assertEqual(RemoteInbox.describe(TransportError("otro_codigo")), "No se pudo copiar al servidor (otro_codigo)")
        self.assertEqual(RemoteInbox.describe(RuntimeError("se rompió")), "No se pudo copiar al servidor: se rompió")
        self.assertLessEqual(len(RemoteInbox.describe(TransportError("remote_command_failed", "x" * 900))), 500)


class RPCTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-fileput-rpc-")
        self.root = Path(self.directory.name) / "Entrada"
        record = {"id": "terminal", "name": "Ventana", "tmux": "s", "cwd": "/tmp"}
        self.local = {"id": "local", "name": "Local", "kind": "local", "cwd": "/tmp", "windows": [record]}
        self.ssh = {"id": "ssh", "name": "Servidor", "kind": "ssh", "credentialId": "cred-1", "windows": []}
        self.connections = {"cred-1": "ssh dani@example.com", "cred-2": "ssh otro@example.org"}
        self.window = types.SimpleNamespace(
            locked=False, surfaces={}, focused_surface=None, vault=types.SimpleNamespace(locked=False),
            store=types.SimpleNamespace(workspaces=[self.local, self.ssh], data={}),
            connection=lambda workspace: self.connections[workspace["credentialId"]])
        self.copies = []
        self.copy_result = lambda command, path, name: "/home/dani/uniconnect-entrada/" + name
        def copy(command, path, name):
            self.copies.append((command, path, name))
            return self.copy_result(command, path, name)
        self.store = FilePutStore(self.root, today=lambda: TODAY, chunk_bytes=8)
        self.rpc = MobileRPC(self.window, types.SimpleNamespace(machine_id="host"), lambda callback: callback(),
                             file_put=self.store, remote_inbox=types.SimpleNamespace(copy=copy))
        self.peers = {"conn-a": "100.64.0.7", "conn-a2": "100.64.0.7", "conn-b": "100.64.0.9"}
        self.rpc.host = types.SimpleNamespace(address="100.64.0.1", port=58465, peer_of=self.peers.get)

    def tearDown(self):
        self.rpc.close_attachments()
        self.directory.cleanup()

    @property
    def day(self):
        return self.root / "20260909"

    def call(self, method, params, connection="conn-a", authorized=lambda: True):
        return self.rpc.dispatch("mobile." + method, params, connection, authorized=authorized)

    def error(self, method, params, connection="conn-a", authorized=lambda: True):
        with self.assertRaises(RPCError) as caught:
            self.call(method, params, connection, authorized)
        return caught.exception.code

    def begin(self, workspace_id="local", name="nota.txt", size=12, connection="conn-a", **extra):
        return self.call("file.begin", {"workspace_id": workspace_id, "name": name, "size": size, **extra}, connection)

    def test_workspace_list_advertises_the_capability(self):
        self.assertEqual(self.call("workspace.list", {})["capabilities"], ["activity.v1", "box_update", "file_put.v1", "transcribe.v1"])

    def test_full_transfer_through_the_rpc_boundary(self):
        data = b"linea uno\nfin"
        ticket = self.begin(name="nota.txt", size=len(data), terminal_id="terminal", mime="text/plain")
        self.assertEqual(ticket["chunk_bytes"], 8)
        transfer = ticket["transfer_id"]
        for index, offset in enumerate(range(0, len(data), 8)):
            encoded = base64.b64encode(data[offset:offset + 8]).decode()
            self.assertEqual(self.call("file.chunk", {"transfer_id": transfer, "index": index, "data": encoded}),
                             {"received_bytes": min(offset + 8, len(data))})
        result = self.call("file.commit", {"transfer_id": transfer, "sha256": sha(data)})
        self.assertEqual(result, {"path": str(self.day / "nota.txt"), "location": "host"})
        self.assertEqual((self.day / "nota.txt").read_bytes(), data)
        self.assertEqual(self.copies, [])

    def test_parameter_validation(self):
        transfer = self.begin()["transfer_id"]
        self.assertEqual(self.error("file.chunk", {"transfer_id": transfer, "index": 0, "data": "!!!!"}), "invalid_params")
        self.assertEqual(self.error("file.chunk", {"transfer_id": transfer, "index": 0, "data": "YWJj"[:-1]}), "invalid_params")
        self.assertEqual(self.error("file.chunk", {"transfer_id": transfer, "index": True, "data": "YWJj"}), "invalid_params")
        self.assertEqual(self.error("file.chunk", {"transfer_id": transfer, "index": 0, "data": 7}), "invalid_params")
        self.assertEqual(self.error("file.chunk", {"index": 0, "data": "YWJj"}), "invalid_params")
        self.assertEqual(self.error("file.commit", {"transfer_id": transfer, "sha256": "corto"}), "invalid_params")
        self.assertEqual(self.error("file.begin", {"workspace_id": "local", "name": "", "size": 1}), "invalid_params")
        self.assertEqual(self.error("file.begin", {"workspace_id": "local", "name": 5, "size": 1}), "invalid_params")
        self.assertEqual(self.error("file.begin", {"workspace_id": "local", "name": "a", "size": "1"}), "invalid_params")
        self.assertEqual(self.error("file.begin", {"workspace_id": "local", "name": "a", "size": 1, "mime": "x\n"}), "invalid_params")
        self.assertEqual(self.error("file.begin", {"workspace_id": "local", "name": "a", "size": 300 * 1024 * 1024}), "too_large")
        self.assertEqual(self.error("file.begin", {"workspace_id": "missing", "name": "a", "size": 1}), "not_found")
        self.assertEqual(self.error("file.begin", {"workspace_id": "local", "name": "a", "size": 1, "terminal_id": "nope"}), "not_found")
        self.assertEqual(self.error("file.begin", {"name": "a", "size": 1}), "invalid_params")
        self.assertTrue((self.day / "nota.txt.part").exists())
        self.assertEqual(self.call("file.abort", {"transfer_id": transfer}), {})
        self.assertEqual(list(self.day.iterdir()), [])

    def test_locked_desktop_and_revoked_device_fail_closed(self):
        transfer = self.begin()["transfer_id"]
        chunk = {"transfer_id": transfer, "index": 0, "data": base64.b64encode(b"12345678").decode()}
        self.window.locked = True
        for method, params in (("file.begin", {"workspace_id": "local", "name": "b", "size": 1}), ("file.chunk", chunk),
                               ("file.commit", {"transfer_id": transfer, "sha256": sha(b"")}),
                               ("file.abort", {"transfer_id": transfer})):
            with self.subTest(method=method):
                self.assertEqual(self.error(method, params), "locked")
        self.window.locked = False
        self.assertEqual(self.error("file.chunk", chunk, authorized=lambda: False), "approval_required")
        self.assertTrue((self.day / "nota.txt.part").exists())
        self.assertEqual(self.call("file.chunk", chunk), {"received_bytes": 8})

    def test_transfer_belongs_to_the_approved_device_not_the_tcp_connection(self):
        transfer = self.begin()["transfer_id"]
        chunk = {"transfer_id": transfer, "index": 0, "data": base64.b64encode(b"12345678").decode()}
        self.assertEqual(self.error("file.chunk", chunk, connection="conn-b"), "not_found")
        self.assertEqual(self.error("file.abort", {"transfer_id": transfer}, connection="conn-b"), "not_found")
        self.assertEqual(self.error("file.chunk", chunk, connection="desconocida"), "not_found")
        self.assertTrue((self.day / "nota.txt.part").exists())
        # El móvil reabre la conexión para abortar tras un fallo: mismo dispositivo, misma transferencia.
        self.rpc.disconnected("conn-a")
        self.assertEqual(self.call("file.chunk", chunk, connection="conn-a2"), {"received_bytes": 8})
        self.assertEqual(self.call("file.abort", {"transfer_id": transfer}, connection="conn-a2"), {})
        self.assertEqual(list(self.day.iterdir()), [])

    def test_edited_box_credential_gives_not_found_and_discards_the_part(self):
        transfer = self.begin(workspace_id="ssh", name="clave.txt", size=4)["transfer_id"]
        self.ssh["credentialId"] = "cred-2"
        chunk = {"transfer_id": transfer, "index": 0, "data": base64.b64encode(b"abcd").decode()}
        self.assertEqual(self.error("file.chunk", chunk), "not_found")
        self.assertEqual(list(self.day.iterdir()), [])
        self.assertEqual(self.error("file.commit", {"transfer_id": transfer, "sha256": sha(b"abcd")}), "not_found")
        transfer = self.begin(workspace_id="local", name="caja.txt", size=0)["transfer_id"]
        self.window.store.workspaces.remove(self.local)
        self.assertEqual(self.error("file.commit", {"transfer_id": transfer, "sha256": sha(b"")}), "not_found")
        self.assertEqual(list(self.day.iterdir()), [])

    def test_ssh_box_commit_copies_with_the_box_connection(self):
        data = b"%PDF-1.7"
        transfer = self.begin(workspace_id="ssh", name="informe.pdf", size=len(data))["transfer_id"]
        self.call("file.chunk", {"transfer_id": transfer, "index": 0, "data": base64.b64encode(data).decode()})
        result = self.call("file.commit", {"transfer_id": transfer, "sha256": sha(data)})
        self.assertEqual(result, {"path": str(self.day / "informe.pdf"), "location": "remote",
                                  "remote_path": "/home/dani/uniconnect-entrada/informe.pdf"})
        command, path, name = self.copies[0]
        self.assertEqual((command.destination, path, name), ("dani@example.com", self.day / "informe.pdf", "informe.pdf"))
        self.assertEqual(path.read_bytes(), data)
        self.copies.clear()
        def failing(command, path, name):
            raise TransportError("sftp_operation_failed", "Permission denied")
        self.copy_result = failing
        transfer = self.begin(workspace_id="ssh", name="informe.pdf", size=len(data))["transfer_id"]
        self.call("file.chunk", {"transfer_id": transfer, "index": 0, "data": base64.b64encode(data).decode()})
        result = self.call("file.commit", {"transfer_id": transfer, "sha256": sha(data)})
        self.assertEqual(result, {"path": str(self.day / "informe-2.pdf"), "location": "host",
                                  "remote_error": "El servidor rechazó la escritura: Permission denied"})
        self.assertEqual((self.day / "informe-2.pdf").read_bytes(), data)

    def test_ssh_commit_with_locked_vault_waits_and_missing_credential_discards(self):
        transfer = self.begin(workspace_id="ssh", name="x.bin", size=0)["transfer_id"]
        self.window.vault.locked = True
        self.assertEqual(self.error("file.commit", {"transfer_id": transfer, "sha256": sha(b"")}), "locked")
        self.window.vault.locked = False
        self.connections.pop("cred-1")
        self.assertEqual(self.error("file.commit", {"transfer_id": transfer, "sha256": sha(b"")}), "not_found")
        self.assertEqual(list(self.day.iterdir()), [])
        self.assertEqual(self.copies, [])


if __name__ == "__main__":
    unittest.main()
