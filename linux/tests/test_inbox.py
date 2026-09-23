"""La bandeja de entrada del móvil: listar, leer y borrar sin salir nunca de la carpeta."""

import base64
import os
import tempfile
import time
import unittest
from pathlib import Path

from uniconnect.inbox import Inbox, kind_of
from uniconnect.mobile_protocol import RPCError

AHORA = 2_000_000_000.0
DIA = 86400


class InboxTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "Entrada"
        self.inbox = Inbox(self.root, clock=lambda: AHORA)

    def tearDown(self):
        self.tmp.cleanup()

    def archivo(self, relativo, tamaño, dias_atras):
        path = self.root / relativo
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * tamaño)
        t = AHORA - dias_atras * DIA
        os.utime(path, (t, t))
        return path

    def test_lista_lo_nuevo_primero_con_tipo_y_total(self):
        self.archivo("20260901/viejo.pdf", 10, 20)
        self.archivo("20260923/video.mp4", 300, 0)
        self.archivo("20260922/foto.JPG", 50, 1)
        r = self.inbox.list()
        self.assertEqual([e["name"] for e in r["entries"]], ["video.mp4", "foto.JPG", "viejo.pdf"])
        self.assertEqual([e["kind"] for e in r["entries"]], ["video", "image", "document"])
        self.assertEqual((r["count"], r["total_bytes"]), (3, 360))
        self.assertTrue(r["entries"][0]["absolute"].endswith("Entrada/20260923/video.mp4"))

    def test_no_lista_subidas_a_medias_ni_ocultos_ni_enlaces(self):
        self.archivo("20260923/bueno.txt", 5, 0)
        self.archivo("20260923/subiendo.mp4.part", 999, 0)
        self.archivo("20260923/.oculto", 7, 0)
        fuera = Path(self.tmp.name) / "secreto.txt"
        fuera.write_text("no")
        (self.root / "20260923" / "enlace.txt").symlink_to(fuera)
        self.assertEqual([e["name"] for e in self.inbox.list()["entries"]], ["bueno.txt"])

    def test_la_bandeja_vacia_o_inexistente_no_falla(self):
        r = self.inbox.list()
        self.assertEqual((r["count"], r["total_bytes"], r["entries"]), (0, 0, []))

    def test_no_se_sale_de_la_carpeta(self):
        self.archivo("20260923/a.txt", 1, 0)
        for mala in ("../fuera.txt", "/etc/passwd", "20260923/../../fuera.txt", "", "a\0b"):
            with self.assertRaises(RPCError, msg=mala):
                self.inbox.resolve(mala)
        fuera = Path(self.tmp.name) / "secreto.txt"
        fuera.write_text("no")
        (self.root / "20260923" / "trampa.txt").symlink_to(fuera)
        with self.assertRaises(RPCError):
            self.inbox.read("20260923/trampa.txt")

    def test_sin_criterio_no_se_borra_nada(self):
        self.archivo("20260923/a.txt", 1, 0)
        with self.assertRaises(RPCError):
            self.inbox.delete()
        self.assertEqual(self.inbox.list()["count"], 1)

    def test_los_criterios_se_suman(self):
        self.archivo("20260901/viejo_grande.mp4", 500, 30)
        self.archivo("20260901/viejo_pequeño.txt", 5, 30)
        self.archivo("20260923/nuevo_grande.mp4", 500, 0)
        r = self.inbox.delete(older_than_days=7, larger_than_bytes=100)
        self.assertEqual((r["deleted"], r["freed_bytes"]), (1, 500))
        self.assertEqual(sorted(e["name"] for e in self.inbox.list()["entries"]), ["nuevo_grande.mp4", "viejo_pequeño.txt"])

    def test_la_simulacion_dice_lo_mismo_sin_tocar_nada(self):
        self.archivo("20260901/a.mp4", 400, 30)
        self.archivo("20260923/b.mp4", 100, 0)
        simulado = self.inbox.delete(older_than_days=7, dry_run=True)
        self.assertEqual((simulado["deleted"], simulado["freed_bytes"], simulado["remaining_bytes"]), (1, 400, 100))
        self.assertEqual(self.inbox.list()["count"], 2)
        real = self.inbox.delete(older_than_days=7)
        self.assertEqual((real["deleted"], real["freed_bytes"], real["remaining_bytes"]), (1, 400, 100))

    def test_borrar_todo_respeta_las_subidas_en_marcha_y_limpia_carpetas_vacias(self):
        self.archivo("20260901/a.txt", 3, 30)
        self.archivo("20260923/b.txt", 3, 0)
        parte = self.archivo("20260923/c.mp4.part", 9, 0)
        r = self.inbox.delete(everything=True)
        self.assertEqual(r["deleted"], 2)
        self.assertTrue(parte.exists(), "una subida en marcha no se borra")
        self.assertFalse((self.root / "20260901").exists(), "la carpeta de día vacía se quita")
        self.assertTrue(self.root.exists(), "la raíz nunca se quita")

    def test_borrar_rutas_concretas(self):
        self.archivo("20260923/a.txt", 3, 0)
        self.archivo("20260923/b.txt", 4, 0)
        r = self.inbox.delete(paths=["20260923/a.txt"])
        self.assertEqual((r["deleted"], r["freed_bytes"]), (1, 3))
        with self.assertRaises(RPCError):
            self.inbox.delete(paths=["../../etc/passwd"])

    def test_leer_por_trozos(self):
        path = self.archivo("20260923/a.bin", 0, 0)
        path.write_bytes(bytes(range(256)) * 10)
        uno = self.inbox.read("20260923/a.bin", 0, 1000)
        dos = self.inbox.read("20260923/a.bin", 1000, 5000)
        self.assertEqual(base64.b64decode(uno["data"]) + base64.b64decode(dos["data"]), bytes(range(256)) * 10)
        self.assertEqual((uno["size"], uno["eof"], dos["eof"]), (2560, False, True))

    def test_tipos(self):
        self.assertEqual([kind_of(n) for n in ("a.HEIC", "b.m4a", "c.webm", "d", "e.xyz")],
                         ["image", "audio", "video", "other", "other"])


class InboxRPCTest(unittest.TestCase):
    """El contrato inbox.v1 por la frontera RPC real: sin permiso o bloqueado, nada."""

    def setUp(self):
        import types
        from uniconnect.mobile_rpc import MobileRPC
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name) / "Entrada"
        (root / "20260923").mkdir(parents=True)
        (root / "20260923" / "foto.jpg").write_bytes(b"123")
        self.window = types.SimpleNamespace(locked=False, surfaces={},
            store=types.SimpleNamespace(workspaces=[], data={}))
        self.rpc = MobileRPC(self.window, types.SimpleNamespace(machine_id="host"), lambda callback: callback(),
                             inbox=Inbox(root, clock=lambda: AHORA))

    def tearDown(self):
        self.rpc.close_attachments()
        self.tmp.cleanup()

    def test_con_permiso_lista_y_borra(self):
        r = self.rpc.dispatch("mobile.inbox.list", {}, "c")
        self.assertEqual(r["entries"][0]["name"], "foto.jpg")
        self.assertEqual(self.rpc.dispatch("mobile.inbox.delete", {"all": True}, "c")["deleted"], 1)

    def test_sin_permiso_no_lista_ni_borra(self):
        for method, params in (("mobile.inbox.list", {}), ("mobile.inbox.delete", {"all": True}),
                               ("mobile.inbox.read", {"path": "20260923/foto.jpg"})):
            with self.assertRaises(RPCError) as error:
                self.rpc.dispatch(method, params, "c", authorized=lambda: False)
            self.assertEqual(error.exception.code, "approval_required")
        self.assertEqual(self.rpc.dispatch("mobile.inbox.list", {}, "c")["count"], 1, "no se borró nada")

    def test_bloqueado_no_responde(self):
        self.window.locked = True
        with self.assertRaises(RPCError) as error:
            self.rpc.dispatch("mobile.inbox.list", {}, "c")
        self.assertEqual(error.exception.code, "locked")

    def test_parametros_malos_se_rechazan(self):
        for params in ({"older_than_days": -1}, {"larger_than_bytes": "mucho"}, {"older_than_days": "7"}):
            with self.assertRaises(RPCError):
                self.rpc.dispatch("mobile.inbox.delete", params, "c")


if __name__ == "__main__":
    unittest.main()
