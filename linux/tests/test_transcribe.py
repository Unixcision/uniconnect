"""transcribe.v1 en el host Linux: límites, motor, orden de whisper, errores y borrado del audio."""

import base64
import os
import struct
import subprocess
import tempfile
import types
import unittest
from pathlib import Path

from uniconnect.mobile_protocol import RPCError
from uniconnect.mobile_rpc import MobileRPC
from uniconnect.transcribe import (CLEANUP_MARGIN, Engine, TranscriptionEngine, clean_transcript,
                                   read_wav_format)


def wav_bytes(seconds=1.0, rate=16000, channels=1, bits=16, audio_format=1):
    """WAV PCM mínimo pero real: cabecera RIFF/fmt/data y silencio del tamaño pedido."""
    frames = int(seconds * rate)
    data = b"\0" * (frames * channels * bits // 8)
    byte_rate = rate * channels * bits // 8
    header = (b"RIFF" + (36 + len(data)).to_bytes(4, "little") + b"WAVE"
              + b"fmt " + (16).to_bytes(4, "little")
              + struct.pack("<HHIIHH", audio_format, channels, rate, byte_rate, channels * bits // 8, bits)
              + b"data" + len(data).to_bytes(4, "little"))
    return header + data


class Result:
    """Lo poco que el motor mira de un proceso terminado."""

    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


class Recorder:
    """Ejecutor inyectado: apunta cada orden y responde lo que el test programe, sin procesos."""

    def __init__(self, test):
        self.test, self.calls, self.handlers = test, [], {}
        self.transcript = "Hola desde el movil\n"
        self.converted_seconds = 1.0
        self.probe_seconds = None

    def __call__(self, argv, *, timeout):
        name = Path(argv[0]).name
        self.calls.append(types.SimpleNamespace(name=name, argv=list(argv), timeout=timeout,
                                                modes=self.test.snapshot_modes()))
        handler = self.handlers.get(name)
        if handler is not None:
            return handler(argv, timeout)
        if name == "ffprobe":
            return Result(stdout="" if self.probe_seconds is None else f"{self.probe_seconds}\n")
        if name == "ffmpeg":
            Path(argv[-1]).write_bytes(wav_bytes(seconds=self.converted_seconds))
            return Result()
        return Result(stdout=self.transcript)

    def argv_of(self, name):
        return next(call.argv for call in self.calls if call.name == name)

    def names(self):
        return [call.name for call in self.calls]


class EngineTestCase(unittest.TestCase):
    """Base con modelos, binarios y relojes falsos; ningún proceso real se ejecuta."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-transcribe-")
        self.root = Path(self.directory.name)
        self.models = self.root / "modelos"
        self.models.mkdir()
        self.temp_root = self.root / "temporales"
        self.temp_root.mkdir()
        self.binaries = {}
        self.now = 1000.0
        self.runner = Recorder(self)
        self.write_model("ggml-small.bin", 900)
        self.write_model("ggml-base.bin", 400)
        self.install("whisper-cli")
        self.install("ffmpeg")

    def tearDown(self):
        self.directory.cleanup()

    def install(self, name, path=None):
        self.binaries[name] = path if path is not None else "/usr/bin/" + name

    def write_model(self, name, size):
        (self.models / name).write_bytes(b"m" * size)

    def snapshot_modes(self):
        """Permisos de todo lo que hay en el temporal mientras el proceso corre."""
        return {item.name: os.stat(item).st_mode & 0o777
                for parent in self.temp_root.iterdir() for item in parent.iterdir()}

    def leftovers(self):
        return sorted(item.name for item in self.temp_root.iterdir())

    def engine(self, **overrides):
        options = dict(model_directory=self.models, threads=3, runner=self.runner,
                       which=self.binaries.get, clock=lambda: self.now, temp_root=self.temp_root,
                       environment={})
        options.update(overrides)
        return TranscriptionEngine(**options)

    def transcribe(self, audio=None, mime="audio/mp4", language="es", engine=None, **overrides):
        engine = engine if engine is not None else self.engine(**overrides)
        return engine.transcribe(audio if audio is not None else b"audio-comprimido", mime, language)

    def code(self, **arguments):
        with self.assertRaises(RPCError) as caught:
            self.transcribe(**arguments)
        return caught.exception.code


class DetectionTests(EngineTestCase):
    def test_binary_order_prefers_whisper_cli_then_whisper_cpp_then_main(self):
        self.install("whisper-cpp")
        self.install("main")
        self.assertEqual(self.engine().resolve().binary, "/usr/bin/whisper-cli")
        del self.binaries["whisper-cli"]
        self.assertEqual(self.engine().resolve().binary, "/usr/bin/whisper-cpp")
        del self.binaries["whisper-cpp"]
        self.assertEqual(self.engine().resolve().binary, "/usr/bin/main")

    def test_configured_binary_must_exist_and_be_executable(self):
        script = self.root / "mi-whisper"
        script.write_text("#!/bin/sh\n")
        with self.assertRaises(RPCError) as caught:
            self.engine(binary=str(script)).resolve()
        self.assertEqual(caught.exception.code, "unsupported")
        script.chmod(0o700)
        self.assertEqual(self.engine(binary=str(script)).resolve().binary, str(script))
        self.assertEqual(self.engine(environment={"UNICONNECT_WHISPER_BIN": str(script)},
                                     model_directory=self.models).resolve().binary, str(script))

    def test_model_is_the_smallest_one_unless_configured(self):
        self.assertEqual(self.engine().resolve().model, self.models / "ggml-base.bin")
        self.write_model("ggml-tiny.bin", 100)
        self.assertEqual(self.engine().resolve().model, self.models / "ggml-tiny.bin")
        self.assertEqual(self.engine(model="ggml-small.bin").resolve().model, self.models / "ggml-small.bin")
        absolute = self.root / "otro.bin"
        absolute.write_bytes(b"x")
        self.assertEqual(self.engine(model=str(absolute)).resolve().model, absolute)
        with self.assertRaises(RPCError) as caught:
            self.engine(model="no-existe.bin").resolve()
        self.assertEqual(caught.exception.code, "unsupported")

    def test_empty_and_missing_model_directory_are_unsupported(self):
        for name in ("ggml-small.bin", "ggml-base.bin"):
            (self.models / name).unlink()
        (self.models / "vacio.bin").write_bytes(b"")
        with self.assertRaises(RPCError) as caught:
            self.engine().resolve()
        self.assertEqual(caught.exception.code, "unsupported")
        self.assertIn(str(self.models), caught.exception.message)
        with self.assertRaises(RPCError) as missing:
            self.engine(model_directory=self.root / "no-hay").resolve()
        self.assertEqual(missing.exception.code, "unsupported")

    def test_unsupported_without_any_binary_mentions_whisper(self):
        self.binaries.clear()
        with self.assertRaises(RPCError) as caught:
            self.engine().resolve()
        self.assertEqual(caught.exception.code, "unsupported")
        self.assertIn("whisper", caught.exception.message)

    def test_detection_is_cached_and_revalidated_after_a_failure(self):
        engine = self.engine()
        self.assertEqual(engine.resolve().model.name, "ggml-base.bin")
        self.write_model("ggml-tiny.bin", 10)
        self.assertEqual(engine.resolve().model.name, "ggml-base.bin")  # Cacheado: no vuelve a mirar.
        self.runner.handlers["whisper-cli"] = lambda argv, timeout: Result(returncode=1, stderr="boom")
        self.assertEqual(self.code(engine=engine), "io_failed")
        self.assertIsNone(engine.engine)
        del self.runner.handlers["whisper-cli"]
        self.assertEqual(engine.resolve().model.name, "ggml-tiny.bin")  # Revalidado tras la avería.

    def test_the_default_budget_answers_before_the_phone_gives_up(self):
        self.assertLessEqual(self.engine().budget + CLEANUP_MARGIN, 90.0)

    def test_default_threads_follow_the_cores_minus_one(self):
        self.assertEqual(TranscriptionEngine.default_threads({"UNICONNECT_WHISPER_THREADS": "2"}), 2)
        self.assertEqual(TranscriptionEngine.default_threads({"UNICONNECT_WHISPER_THREADS": "99"}), 8)
        self.assertEqual(TranscriptionEngine.default_threads({"UNICONNECT_WHISPER_THREADS": "cero"}),
                         max(1, min(8, (os.cpu_count() or 2) - 1)))
        self.assertGreaterEqual(TranscriptionEngine.default_threads({}), 1)

    def test_default_model_directory_follows_xdg(self):
        directory = TranscriptionEngine.default_model_directory({"XDG_DATA_HOME": "/datos"})
        self.assertEqual(directory, Path("/datos/uniconnect/whisper"))
        self.assertEqual(TranscriptionEngine.default_model_directory({}),
                         Path.home() / ".local/share/uniconnect/whisper")


class CommandTests(EngineTestCase):
    def test_compressed_audio_is_converted_and_then_transcribed(self):
        result = self.transcribe(mime="audio/ogg")
        self.assertEqual(self.runner.names(), ["ffmpeg", "whisper-cli"])
        conversion = self.runner.argv_of("ffmpeg")
        self.assertEqual(conversion[0], "/usr/bin/ffmpeg")
        self.assertIn("-nostdin", conversion)
        self.assertEqual(conversion[conversion.index("-i") + 1][-4:], ".ogg")
        for flag, value in (("-ac", "1"), ("-ar", "16000"), ("-c:a", "pcm_s16le"), ("-f", "wav")):
            self.assertEqual(conversion[conversion.index(flag) + 1], value)
        self.assertTrue(conversion[-1].endswith("audio16k.wav"))
        order = self.runner.argv_of("whisper-cli")
        self.assertEqual(order[0], "/usr/bin/whisper-cli")
        self.assertEqual(order[order.index("--model") + 1], str(self.models / "ggml-base.bin"))
        self.assertEqual(order[order.index("--file") + 1], conversion[-1])
        self.assertEqual(order[order.index("--language") + 1], "es")
        self.assertEqual(order[order.index("--threads") + 1], "3")
        self.assertIn("--no-timestamps", order)
        self.assertEqual(result["text"], "Hola desde el movil")
        self.assertEqual(result["engine"], "whisper.cpp/ggml-base.bin")
        self.assertEqual(result["seconds"], 1.0)
        self.assertEqual(result["took_ms"], 0)

    def test_language_is_auto_when_the_phone_sends_none(self):
        def language():
            order = self.runner.argv_of("whisper-cli")
            return order[order.index("--language") + 1]
        self.transcribe(language=None)
        self.assertEqual(language(), "auto")
        for wrong in ("", "castellano", "ES-es", 7, "e"):
            self.assertEqual(self.code(language=wrong), "invalid_params")
        self.runner.calls.clear()
        self.transcribe(language="EN")
        self.assertEqual(language(), "en")

    def test_ready_wav_skips_ffmpeg_even_when_it_exists(self):
        result = self.transcribe(audio=wav_bytes(seconds=2.5), mime="audio/wav")
        self.assertEqual(self.runner.names(), ["whisper-cli"])
        self.assertTrue(self.runner.argv_of("whisper-cli")[4].endswith("entrada.wav"))
        self.assertEqual(result["seconds"], 2.5)

    def test_wav_with_the_wrong_geometry_is_converted(self):
        self.transcribe(audio=wav_bytes(seconds=1, rate=44100, channels=2), mime="audio/x-wav")
        self.assertEqual(self.runner.names(), ["ffmpeg", "whisper-cli"])

    def test_unsupported_when_ffmpeg_is_missing_and_the_audio_is_not_ready(self):
        del self.binaries["ffmpeg"]
        for audio, mime in ((b"comprimido", "audio/mp4"), (wav_bytes(rate=8000), "audio/wav")):
            with self.assertRaises(RPCError) as caught:
                self.transcribe(audio=audio, mime=mime)
            self.assertEqual(caught.exception.code, "unsupported")
            self.assertIn("ffmpeg", caught.exception.message)
        self.assertEqual(self.runner.names(), [])
        self.assertEqual(self.transcribe(audio=wav_bytes(), mime="audio/wav")["text"], "Hola desde el movil")

    def test_mime_types_and_extensions(self):
        engine = self.engine()
        for mime, extension in (("audio/mp4", ".m4a"), ("AUDIO/MP4; codecs=mp4a.40.2", ".m4a"),
                                ("audio/ogg", ".ogg"), ("audio/wav", ".wav"), ("audio/wave", ".wav")):
            self.assertEqual(engine.extension_for(mime), extension)
        for wrong in ("video/mp4", "text/plain", "", None, 5):
            with self.assertRaises(RPCError) as caught:
                engine.extension_for(wrong)
            self.assertEqual(caught.exception.code, "invalid_params")


class LimitTests(EngineTestCase):
    def test_audio_over_six_mebibytes_is_too_large(self):
        engine = self.engine()
        self.assertEqual(engine.max_bytes, 6 * 1024 * 1024)
        with self.assertRaises(RPCError) as caught:
            engine.transcribe(b"x" * (engine.max_bytes + 1), "audio/mp4", "es")
        self.assertEqual(caught.exception.code, "too_large")
        self.assertEqual(self.runner.names(), [])
        self.assertEqual(self.leftovers(), [])

    def test_empty_audio_is_invalid(self):
        self.assertEqual(self.code(audio=b""), "invalid_params")
        self.assertEqual(self.code(audio="no son bytes"), "invalid_params")

    def test_ffprobe_duration_over_five_minutes_is_rejected_before_converting(self):
        self.install("ffprobe")
        self.runner.probe_seconds = 301.0
        with self.assertRaises(RPCError) as caught:
            self.transcribe()
        self.assertEqual(caught.exception.code, "too_large")
        self.assertEqual(self.runner.names(), ["ffprobe"])
        self.assertEqual(self.leftovers(), [])
        self.runner.probe_seconds = 299.5
        self.assertEqual(self.transcribe()["seconds"], 1.0)  # La conversión manda sobre la sonda.

    def test_a_long_wav_is_rejected_from_its_own_header(self):
        with self.assertRaises(RPCError) as caught:
            self.transcribe(audio=wav_bytes(seconds=301), mime="audio/wav")
        self.assertEqual(caught.exception.code, "too_large")
        self.assertEqual(self.runner.names(), [])

    def test_a_long_conversion_is_rejected_after_ffmpeg(self):
        self.runner.converted_seconds = 400.0
        with self.assertRaises(RPCError) as caught:
            self.transcribe()
        self.assertEqual(caught.exception.code, "too_large")
        self.assertEqual(self.runner.names(), ["ffmpeg"])
        self.assertEqual(self.leftovers(), [])

    def test_an_unreadable_probe_does_not_block_the_transcription(self):
        self.install("ffprobe")
        self.runner.handlers["ffprobe"] = lambda argv, timeout: Result(stdout="N/A")
        self.assertEqual(self.transcribe()["text"], "Hola desde el movil")
        self.runner.handlers["ffprobe"] = lambda argv, timeout: (_ for _ in ()).throw(OSError("sin ffprobe"))
        self.assertEqual(self.transcribe()["text"], "Hola desde el movil")


class FailureTests(EngineTestCase):
    def test_engine_failure_and_missing_binary_map_to_io_failed(self):
        self.runner.handlers["whisper-cli"] = lambda argv, timeout: Result(returncode=1, stderr="no model")
        self.assertEqual(self.code(), "io_failed")
        self.runner.handlers["whisper-cli"] = lambda argv, timeout: (_ for _ in ()).throw(OSError("ENOENT"))
        self.assertEqual(self.code(), "io_failed")
        self.assertEqual(self.leftovers(), [])

    def test_conversion_failure_maps_to_io_failed(self):
        self.runner.handlers["ffmpeg"] = lambda argv, timeout: Result(returncode=1, stderr="Invalid data")
        self.assertEqual(self.code(), "io_failed")
        self.runner.handlers["ffmpeg"] = lambda argv, timeout: Result()  # Sale bien pero no deja el WAV.
        self.assertEqual(self.code(), "io_failed")
        self.assertEqual(self.leftovers(), [])

    def test_a_process_timeout_maps_to_io_failed_and_clears_the_cache(self):
        engine = self.engine()
        def slow(argv, timeout):
            raise subprocess.TimeoutExpired(argv, timeout)
        self.runner.handlers["whisper-cli"] = slow
        self.assertEqual(self.code(engine=engine), "io_failed")
        self.assertIsNone(engine.engine)
        self.assertEqual(self.leftovers(), [])

    def test_the_budget_is_shared_by_conversion_and_transcription(self):
        engine = self.engine(budget=30.0)
        def slow_conversion(argv, timeout):
            self.now += 10.0
            Path(argv[-1]).write_bytes(wav_bytes())
            return Result()
        self.runner.handlers["ffmpeg"] = slow_conversion
        result = self.transcribe(engine=engine)
        conversion, transcription = self.runner.calls
        self.assertAlmostEqual(conversion.timeout, 30.0 - CLEANUP_MARGIN)
        self.assertAlmostEqual(transcription.timeout, 20.0 - CLEANUP_MARGIN)
        self.assertEqual(result["took_ms"], 10000)

    def test_an_exhausted_budget_fails_before_calling_the_engine(self):
        engine = self.engine(budget=30.0)
        def eternal(argv, timeout):
            self.now += 40.0
            Path(argv[-1]).write_bytes(wav_bytes())
            return Result()
        self.runner.handlers["ffmpeg"] = eternal
        with self.assertRaises(RPCError) as caught:
            self.transcribe(engine=engine)
        self.assertEqual(caught.exception.code, "io_failed")
        self.assertEqual(self.runner.names(), ["ffmpeg"])
        self.assertEqual(self.leftovers(), [])

    def test_a_cancelled_call_stops_and_leaves_nothing_behind(self):
        engine = self.engine()
        with self.assertRaises(RPCError) as caught:
            engine.transcribe(b"audio", "audio/mp4", "es", cancelled=lambda: True)
        self.assertEqual(caught.exception.code, "io_failed")
        self.assertEqual(self.runner.names(), [])
        self.assertEqual(self.leftovers(), [])


class PrivacyTests(EngineTestCase):
    def test_the_audio_is_private_while_it_exists_and_is_deleted_afterwards(self):
        result = self.transcribe()
        self.assertEqual(self.leftovers(), [])
        modes = self.runner.calls[0].modes
        self.assertEqual(modes, {"entrada.m4a": 0o600})
        self.assertEqual(self.runner.calls[1].modes, {"entrada.m4a": 0o600, "audio16k.wav": 0o600})
        self.assertNotIn("audio", result)

    def test_the_temporary_directory_is_private_and_removed_on_every_path(self):
        seen = []
        def peek(argv, timeout):
            seen.extend((item.name, item.stat().st_mode & 0o777) for item in self.temp_root.iterdir())
            return Result(returncode=1)
        self.runner.handlers["ffmpeg"] = peek
        self.assertEqual(self.code(), "io_failed")
        self.assertEqual(len(seen), 1)
        self.assertTrue(seen[0][0].startswith("uniconnect-audio-"))
        self.assertEqual(seen[0][1], 0o700)
        self.assertEqual(self.leftovers(), [])

    def test_no_error_message_carries_the_audio_or_the_text(self):
        self.runner.handlers["whisper-cli"] = lambda argv, timeout: Result(returncode=1, stderr="secreto dicho")
        with self.assertRaises(RPCError) as caught:
            self.transcribe(audio=b"palabras secretas")
        self.assertNotIn("secreto", caught.exception.message)
        self.assertNotIn("palabras", caught.exception.message)


class TextTests(unittest.TestCase):
    def test_transcript_is_cleaned_up_into_one_dictation_line(self):
        self.assertEqual(clean_transcript(" Hola  mundo \n\n  segunda linea \n"), "Hola mundo segunda linea")
        self.assertEqual(clean_transcript("[BLANK_AUDIO]\n[ Silence ]\nTexto\n"), "Texto")
        self.assertEqual(clean_transcript("[00:00:00.000 --> 00:00:02.000]  Con marca\n"), "Con marca")
        self.assertEqual(clean_transcript(""), "")
        self.assertEqual(clean_transcript("[MUSIC]"), "")

    def test_wav_header_reading(self):
        with tempfile.TemporaryDirectory(prefix="uc-wav-") as directory:
            path = Path(directory) / "a.wav"
            path.write_bytes(wav_bytes(seconds=3))
            fields = read_wav_format(path)
            self.assertTrue(fields.ready_for_whisper)
            self.assertEqual(fields.seconds, 3.0)
            path.write_bytes(wav_bytes(seconds=1, rate=44100, channels=2))
            self.assertFalse(read_wav_format(path).ready_for_whisper)
            path.write_bytes(b"no soy un wav")
            self.assertIsNone(read_wav_format(path))
            truncated = wav_bytes(seconds=2)
            path.write_bytes(truncated[:40] + b"data" + (0).to_bytes(4, "little") + truncated[48:])
            self.assertAlmostEqual(read_wav_format(path).seconds, 2.0, places=3)

    def test_engine_name_hides_the_host_paths(self):
        engine = Engine(binary="/usr/bin/whisper-cli", model=Path("/home/dani/modelos/ggml-base.bin"), threads=3)
        self.assertEqual(engine.name, "whisper.cpp/ggml-base.bin")


class RPCTests(EngineTestCase):
    def setUp(self):
        super().setUp()
        record = {"id": "terminal", "name": "Ventana", "cwd": "/tmp"}
        self.local = {"id": "local", "name": "Local", "kind": "local", "cwd": "/tmp", "windows": [record]}
        self.window = types.SimpleNamespace(
            locked=False, surfaces={}, focused_surface=None, activity=None,
            store=types.SimpleNamespace(workspaces=[self.local], data={}))
        self.rpc = MobileRPC(self.window, types.SimpleNamespace(machine_id="host"), lambda callback: callback(),
                             transcription=self.engine())
        self.rpc.host = types.SimpleNamespace(address="100.64.0.1", port=58465, peer_of=lambda value: "100.64.0.7")

    def tearDown(self):
        self.rpc.close_attachments()
        super().tearDown()

    def call(self, params, authorized=lambda: True):
        return self.rpc.dispatch("mobile.audio.transcribe", params, "conn-a", authorized=authorized)

    def error(self, params, authorized=lambda: True):
        with self.assertRaises(RPCError) as caught:
            self.call(params, authorized)
        return caught.exception.code

    def request(self, audio=b"comprimido", **extra):
        return {"audio": base64.b64encode(audio).decode(), "mime": "audio/mp4", **extra}

    def test_workspace_list_advertises_the_capability(self):
        self.assertEqual(self.rpc.dispatch("mobile.workspace.list", {}, "conn-a")["capabilities"],
                         ["activity.v1", "box_update", "file_put.v1", "transcribe.v1"])

    def test_a_transcription_through_the_rpc_boundary(self):
        result = self.call(self.request(language="es", workspace_id="local", terminal_id="terminal"))
        self.assertEqual(result, {"text": "Hola desde el movil", "engine": "whisper.cpp/ggml-base.bin",
                                  "seconds": 1.0, "took_ms": 0})
        self.assertEqual(self.runner.names(), ["ffmpeg", "whisper-cli"])
        self.assertEqual(self.leftovers(), [])

    def test_bad_parameters_are_rejected_before_any_work(self):
        self.assertEqual(self.error({"mime": "audio/mp4"}), "invalid_params")
        self.assertEqual(self.error({"audio": "", "mime": "audio/mp4"}), "invalid_params")
        self.assertEqual(self.error({"audio": "no es base64!!", "mime": "audio/mp4"}), "invalid_params")
        self.assertEqual(self.error({"audio": base64.b64encode(b"x").decode()}), "invalid_params")
        self.assertEqual(self.error(self.request(language="klingon")), "invalid_params")
        self.assertEqual(self.error({"audio": "A" * (9 * 1024 * 1024), "mime": "audio/mp4"}), "too_large")
        self.assertEqual(self.runner.names(), [])

    def test_a_locked_or_revoked_desktop_refuses_before_transcribing(self):
        self.window.locked = True
        self.assertEqual(self.error(self.request()), "locked")
        self.window.locked = False
        self.assertEqual(self.error(self.request(), authorized=lambda: False), "approval_required")
        self.assertEqual(self.runner.names(), [])

    def test_the_optional_context_must_still_exist(self):
        self.assertEqual(self.error(self.request(workspace_id="fantasma")), "not_found")
        self.assertEqual(self.error(self.request(workspace_id="local", terminal_id="fantasma")), "not_found")
        self.assertEqual(self.runner.names(), [])

    def test_a_host_without_whisper_answers_unsupported(self):
        self.binaries.clear()
        self.rpc.transcription = self.engine()
        self.assertEqual(self.error(self.request()), "unsupported")


if __name__ == "__main__":
    unittest.main()
