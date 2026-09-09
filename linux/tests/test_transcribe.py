"""transcribe.v1 en el host Linux: límites, motor, orden de whisper, errores y borrado del audio."""

import base64
import os
import shutil
import struct
import subprocess
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path

from uniconnect.mobile_protocol import MAX_FRAME, RPCError
from uniconnect.mobile_rpc import MobileRPC
from uniconnect.transcribe import (CLEANUP_MARGIN, CancelledTranscription, Engine, SubprocessRunner,
                                   TranscriptionEngine, clean_transcript, is_marker, process_alive,
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
        self.inside = False

    def __call__(self, argv, *, timeout, cancelled=lambda: False):
        name = Path(argv[0]).name
        self.calls.append(types.SimpleNamespace(name=name, argv=list(argv), timeout=timeout,
                                                modes=self.test.snapshot_modes(), cancelled=cancelled))
        self.inside = True
        try:
            result = self.produce(name, argv, timeout)
            if cancelled():  # Lo que hace el de verdad: matar al hijo en vez de entregar su salida.
                raise CancelledTranscription()
            return result
        finally:
            self.inside = False

    def produce(self, name, argv, timeout):
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
        self.work = self.root / "trabajo"
        self.work.mkdir()
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
                for parent in self.work.iterdir() for item in parent.iterdir()}

    def leftovers(self):
        return sorted(item.name for item in self.work.iterdir())

    def engine(self, **overrides):
        options = dict(model_directory=self.models, threads=3, runner=self.runner,
                       which=self.binaries.get, clock=lambda: self.now, work_directory=self.work,
                       environment={})
        options.update(overrides)
        return TranscriptionEngine(**options)

    def transcribe(self, audio=None, mime="audio/mp4", language="es", engine=None, owner="", **overrides):
        engine = engine if engine is not None else self.engine(**overrides)
        return engine.transcribe(audio if audio is not None else b"audio-comprimido", mime, language, owner=owner)

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
        engine = TranscriptionEngine(model_directory=self.models, environment={})
        self.assertEqual(engine.budget, 90.0)  # El plazo acordado con el movil.
        self.assertLess(engine.budget - CLEANUP_MARGIN, 90.0)  # Y el motor para antes de agotarlo.

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
    def test_audio_over_three_mebibytes_is_too_large_and_fits_in_a_frame(self):
        engine = self.engine()
        self.assertEqual(engine.max_bytes, 3 * 1024 * 1024)
        # El maximo, ya en base64 y con el JSON alrededor, tiene que caber en un marco.
        self.assertLess((engine.max_bytes * 4) // 3 + 4096, MAX_FRAME)
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

    def test_a_long_wav_is_rejected_from_its_own_header_not_from_its_size(self):
        # 301 s a 8 kHz y 8 bits son 2,4 MB: cabe de sobra en el limite de 3 MiB, asi
        # que lo que lo rechaza es la duracion que declara su cabecera.
        audio = wav_bytes(seconds=301, rate=8000, bits=8)
        self.assertLess(len(audio), self.engine().max_bytes)
        with self.assertRaises(RPCError) as caught:
            self.transcribe(audio=audio, mime="audio/wav")
        self.assertEqual(caught.exception.code, "too_large")
        self.assertEqual(self.runner.names(), [])

    def test_a_lying_mime_does_not_get_the_duration_it_claims(self):
        """Un mp4 largo disfrazado de WAV se mide por su contenido, con ffprobe."""
        self.install("ffprobe")
        self.runner.probe_seconds = 900.0
        with self.assertRaises(RPCError) as caught:
            self.transcribe(audio=b"\x00\x00\x00 ftypmp42" + b"z" * 2048, mime="audio/wav")
        self.assertEqual(caught.exception.code, "too_large")
        self.assertEqual(self.runner.names(), ["ffprobe"])
        self.assertEqual(self.leftovers(), [])

    def test_a_lying_mime_without_ffprobe_is_caught_after_converting(self):
        self.runner.converted_seconds = 900.0
        with self.assertRaises(RPCError) as caught:
            self.transcribe(audio=b"no soy un wav", mime="audio/wav")
        self.assertEqual(caught.exception.code, "too_large")
        self.assertEqual(self.runner.names(), ["ffmpeg"])
        self.assertEqual(self.leftovers(), [])

    def test_a_real_wav_is_measured_from_its_own_data_not_from_ffprobe(self):
        self.install("ffprobe")
        self.runner.probe_seconds = 900.0  # Mentira del contenedor: manda la cabecera real.
        self.assertEqual(self.transcribe(audio=wav_bytes(seconds=2), mime="audio/mp4")["seconds"], 2.0)
        self.assertEqual(self.runner.names(), ["whisper-cli"])

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


class ConversionLimitTests(EngineTestCase):
    def test_the_conversion_is_bounded_in_time_and_in_bytes(self):
        engine = self.engine()
        self.transcribe(engine=engine)
        order = self.runner.argv_of("ffmpeg")
        self.assertEqual(float(order[order.index("-t") + 1]), 305.0)  # Cinco minutos y un margen.
        self.assertEqual(int(order[order.index("-fs") + 1]), engine.conversion_bytes)
        self.assertGreater(engine.conversion_bytes, 300 * 32000)

    def test_output_that_hits_the_byte_ceiling_is_refused_not_truncated(self):
        engine = self.engine()
        def brimming(argv, timeout):
            Path(argv[-1]).write_bytes(b"RIFF" + b"\0" * (engine.conversion_bytes - 4))
            return Result()
        self.runner.handlers["ffmpeg"] = brimming
        with self.assertRaises(RPCError) as caught:
            self.transcribe(engine=engine)
        self.assertEqual(caught.exception.code, "too_large")
        self.assertEqual(self.runner.names(), ["ffmpeg"])  # Nada de transcribir un recorte.
        self.assertEqual(self.leftovers(), [])

    def test_an_unverifiable_conversion_is_a_failure_not_a_transcription(self):
        for content in (b"esto no es un wav", wav_bytes(seconds=1, rate=44100)):
            self.runner.calls.clear()
            def broken(argv, timeout, content=content):
                Path(argv[-1]).write_bytes(content)
                return Result()
            self.runner.handlers["ffmpeg"] = broken
            with self.assertRaises(RPCError) as caught:
                self.transcribe()
            self.assertEqual(caught.exception.code, "io_failed")
            self.assertEqual(self.runner.names(), ["ffmpeg"])
        self.assertEqual(self.leftovers(), [])


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


class ConcurrencyTests(EngineTestCase):
    def take(self, engine, owner, budget=None):
        deadline = engine.clock() + (budget if budget is not None else engine.budget)
        engine.claim(owner, deadline, lambda: False)

    def refused(self, engine, owner, budget=None):
        with self.assertRaises(RPCError) as caught:
            self.take(engine, owner, budget)
        self.assertEqual(caught.exception.code, "busy")
        return caught.exception.message

    def test_one_job_per_device_and_two_in_total(self):
        engine = self.engine(turn_seconds=0.0)
        self.take(engine, "movil-a")
        self.assertIn("este dispositivo", self.refused(engine, "movil-a"))
        self.take(engine, "movil-b")
        self.assertIn("otro audio", self.refused(engine, "movil-c"))
        engine.release("movil-a")
        self.take(engine, "movil-c")
        self.assertEqual(sorted(engine.running), ["movil-b", "movil-c"])

    def test_a_full_host_waits_for_a_turn_and_then_gives_up(self):
        engine = self.engine(turn_seconds=0.2, clock=time.monotonic)
        self.take(engine, "movil-a")
        self.take(engine, "movil-b")
        freed = threading.Timer(0.05, lambda: engine.release("movil-a"))
        freed.daemon = True
        freed.start()
        engine.claim("movil-c", time.monotonic() + 30, lambda: False)  # Espera y entra.
        self.assertEqual(sorted(engine.running), ["movil-b", "movil-c"])
        started = time.monotonic()
        self.assertIn("otro audio", self.refused(engine, "movil-d"))
        self.assertGreater(time.monotonic() - started, 0.1)  # Ha esperado su turno antes de rendirse.

    def test_the_wait_never_eats_the_budget_it_needs_to_transcribe(self):
        engine = self.engine(turn_seconds=60.0)
        self.take(engine, "movil-a")
        self.take(engine, "movil-b")
        started = self.now
        self.assertIn("otro audio", self.refused(engine, "movil-c", budget=CLEANUP_MARGIN))
        self.assertEqual(self.now, started)  # El reloj no avanza: no se ha esperado nada.

    def test_a_second_dictation_from_the_same_device_is_refused_while_the_first_runs(self):
        engine, refused = self.engine(), []
        def busy(argv, timeout):
            with self.assertRaises(RPCError) as caught:
                engine.transcribe(b"otro", "audio/mp4", "es", owner="movil-a")
            refused.append(caught.exception.code)
            Path(argv[-1]).write_bytes(wav_bytes())
            return Result()
        self.runner.handlers["ffmpeg"] = busy
        engine.transcribe(b"audio", "audio/mp4", "es", owner="movil-a")
        self.assertEqual(refused, ["busy"])
        self.assertEqual(engine.running, [])  # El turno se libera al terminar.

    def test_a_cancelled_or_expired_job_also_frees_its_slot(self):
        engine = self.engine(budget=30.0)
        def eternal(argv, timeout):
            self.now += 40.0
            Path(argv[-1]).write_bytes(wav_bytes())
            return Result()
        self.runner.handlers["ffmpeg"] = eternal
        self.assertEqual(self.code(engine=engine, owner="movil-a"), "io_failed")
        self.assertEqual(engine.running, [])  # Presupuesto agotado.
        del self.runner.handlers["ffmpeg"]
        with self.assertRaises(RPCError):
            engine.transcribe(b"audio", "audio/mp4", "es", owner="movil-a", cancelled=lambda: True)
        self.assertEqual(engine.running, [])  # Cancelacion.
        self.assertEqual(self.transcribe(engine=self.engine(), owner="movil-a")["text"], "Hola desde el movil")

    def test_every_ending_releases_the_turn(self):
        engine = self.engine()
        self.runner.handlers["whisper-cli"] = lambda argv, timeout: Result(returncode=1)
        self.assertEqual(self.code(engine=engine, owner="movil-a"), "io_failed")
        self.assertEqual(engine.running, [])
        self.assertEqual(self.code(engine=engine, mime="video/mp4"), "invalid_params")
        self.assertEqual(engine.running, [])
        self.binaries.clear()
        self.assertEqual(self.code(engine=self.engine(), owner="movil-a"), "unsupported")
        self.assertEqual(engine.running, [])


class CancellationTests(EngineTestCase):
    def switch(self, after):
        """Un `cancelled` que dice que sí a partir de la llamada `after`."""
        state = {"calls": 0}
        def cancelled():
            state["calls"] += 1
            return state["calls"] > after
        return cancelled

    def during(self, name):
        """Un `cancelled` que se enciende mientras corre ese proceso, como una desconexion."""
        return lambda: self.runner.inside and self.runner.names()[-1:] == [name]

    def transcribe_with(self, cancelled, engine=None):
        engine = engine if engine is not None else self.engine()
        with self.assertRaises(RPCError) as caught:
            engine.transcribe(b"audio", "audio/mp4", "es", owner="movil-a", cancelled=cancelled)
        self.assertEqual(caught.exception.code, "io_failed")
        self.assertIn("cancel", caught.exception.message)
        return engine

    def test_cancelling_during_the_conversion_stops_there(self):
        alive = []
        def convert(argv, timeout):
            alive.append(self.leftovers())  # El audio existe mientras ffmpeg trabaja.
            Path(argv[-1]).write_bytes(wav_bytes())
            return Result()
        self.runner.handlers["ffmpeg"] = convert
        engine = self.transcribe_with(self.during("ffmpeg"))
        self.assertEqual(self.runner.names(), ["ffmpeg"])  # Whisper ni se llega a lanzar.
        self.assertEqual(len(alive[0]), 1)
        self.assertEqual(self.leftovers(), [])
        self.assertEqual(engine.running, [])

    def test_cancelling_during_whisper_kills_it_and_returns_no_text(self):
        engine = self.engine()
        def convert(argv, timeout):
            Path(argv[-1]).write_bytes(wav_bytes())
            return Result()
        self.runner.handlers["ffmpeg"] = convert
        # El ejecutor simulado hace lo que el de verdad: si le cancelan, avisa en vez
        # de devolver la transcripcion que whisper hubiera escrito.
        self.runner.handlers["whisper-cli"] = lambda argv, timeout: Result(stdout="texto que no debe salir")
        self.transcribe_with(self.during("whisper-cli"), engine=engine)
        self.assertEqual(self.runner.names(), ["ffmpeg", "whisper-cli"])
        self.assertEqual(self.leftovers(), [])

    def test_text_already_transcribed_is_dropped_when_the_phone_left(self):
        engine, seen = self.engine(), []
        def convert(argv, timeout):
            Path(argv[-1]).write_bytes(wav_bytes())
            return Result()
        self.runner.handlers["ffmpeg"] = convert
        def late(argv, timeout):
            seen.append("transcrito")
            return Result(stdout="Hola")
        self.runner.handlers["whisper-cli"] = late
        # Se cancela justo despues de que el motor termine: el texto existe y se tira.
        finished = lambda: not self.runner.inside and "whisper-cli" in self.runner.names()
        self.transcribe_with(finished, engine=engine)
        self.assertEqual(seen, ["transcrito"])
        self.assertEqual(self.leftovers(), [])

    def test_the_real_runner_kills_a_child_that_ignores_the_polite_signal(self):
        runner, started = SubprocessRunner(), time.monotonic()
        with self.assertRaises(CancelledTranscription):
            runner(["/bin/sh", "-c", "trap '' TERM; sleep 30"], timeout=30, cancelled=self.switch(after=1))
        self.assertLess(time.monotonic() - started, runner.GRACE_SECONDS + 3)

    def test_the_real_runner_stops_a_child_that_outlives_its_deadline(self):
        runner, started = SubprocessRunner(), time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            runner(["/bin/sh", "-c", "sleep 30"], timeout=0.2)
        self.assertLess(time.monotonic() - started, 3)

    def test_the_real_runner_returns_output_and_status(self):
        result = SubprocessRunner()(["/bin/sh", "-c", "printf hola; exit 3"], timeout=10)
        self.assertEqual((result.returncode, result.stdout), (3, "hola"))


class OrphanTests(EngineTestCase):
    def make(self, name, age=0.0):
        directory = self.work / name
        directory.mkdir()
        (directory / "entrada.m4a").write_bytes(b"audio")
        stamp = time.time() - age
        os.utime(directory, (stamp, stamp))
        return directory

    def test_a_crash_leaves_audio_and_the_next_start_deletes_it(self):
        engine = self.engine(alive=lambda pid: pid == os.getpid())
        mine = self.make(f"{os.getpid()}-vivo")
        dead = self.make("999999-muerto")
        self.assertEqual(engine.sweep_orphans(), 1)
        self.assertTrue(mine.exists())  # Otra instancia viva no se toca.
        self.assertFalse(dead.exists())

    def test_old_leftovers_go_even_when_the_pid_was_recycled(self):
        engine = self.engine(alive=lambda pid: True)
        old = self.make(f"{os.getpid()}-antiguo", age=700.0)
        fresh = self.make(f"{os.getpid()}-reciente", age=10.0)
        strange = self.make("sin-pid", age=700.0)
        self.assertEqual(engine.sweep_orphans(), 2)
        self.assertFalse(old.exists())
        self.assertFalse(strange.exists())
        self.assertTrue(fresh.exists())

    def test_a_failed_deletion_is_noticed_and_retried_by_the_sweep(self):
        refusals = []
        def stubborn(directory):
            refusals.append(Path(directory))
            raise OSError("no se puede borrar")
        engine = self.engine(remove=stubborn)
        self.assertEqual(self.transcribe(engine=engine)["text"], "Hola desde el movil")
        self.assertEqual(len(refusals), 2)  # Lo intenta dos veces antes de rendirse.
        left = self.leftovers()
        self.assertEqual(len(left), 1)  # El audio sigue en disco, y el motor lo sabe.
        self.assertEqual([item.name for item in engine.undeleted], left)
        self.assertEqual(engine.active, set())
        engine.remove = shutil.rmtree
        self.assertEqual(engine.sweep_orphans(), 1)
        self.assertEqual(self.leftovers(), [])
        self.assertEqual(engine.undeleted, [])

    def test_the_sweep_never_takes_a_directory_that_is_in_use(self):
        engine = self.engine()
        engine.work_directory.mkdir(parents=True, exist_ok=True)
        mine = engine.workspace()
        (mine / "entrada.m4a").write_bytes(b"audio")
        os.utime(mine, (0, 0))  # Antiquisimo, pero en uso: no se toca.
        self.assertEqual(engine.sweep_orphans(), 0)
        self.assertTrue(mine.exists())
        self.assertTrue(engine.discard(mine))
        self.assertEqual(engine.active, set())

    def test_the_sweep_survives_a_missing_directory_and_stray_files(self):
        engine = self.engine(alive=lambda pid: False)
        self.assertEqual(self.engine(work_directory=self.root / "no-hay").sweep_orphans(), 0)
        stray = self.work / "1-suelto.wav"
        stray.write_bytes(b"x")
        self.assertEqual(engine.sweep_orphans(), 1)
        self.assertFalse(stray.exists())

    def test_a_live_transcription_is_not_swept_by_another_instance(self):
        engine, seen = self.engine(), []
        other = self.engine(alive=process_alive)
        def sweeping(argv, timeout):
            other.sweep_orphans()  # Otra instancia arranca en mitad de este dictado.
            seen.append(self.leftovers())
            Path(argv[-1]).write_bytes(wav_bytes())
            return Result()
        self.runner.handlers["ffmpeg"] = sweeping
        self.assertEqual(engine.transcribe(b"audio", "audio/mp4", "es")["text"], "Hola desde el movil")
        self.assertEqual(len(seen[0]), 1)
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
            seen.extend((item.name, item.stat().st_mode & 0o777) for item in self.work.iterdir())
            return Result(returncode=1)
        self.runner.handlers["ffmpeg"] = peek
        self.assertEqual(self.code(), "io_failed")
        self.assertEqual(len(seen), 1)
        self.assertTrue(seen[0][0].startswith(f"{os.getpid()}-"))
        self.assertEqual(seen[0][1], 0o700)
        self.assertEqual(self.engine().work_directory, self.work)
        self.assertEqual(self.leftovers(), [])

    def test_no_error_message_carries_the_audio_or_the_text(self):
        self.runner.handlers["whisper-cli"] = lambda argv, timeout: Result(returncode=1, stderr="secreto dicho")
        with self.assertRaises(RPCError) as caught:
            self.transcribe(audio=b"palabras secretas")
        self.assertNotIn("secreto", caught.exception.message)
        self.assertNotIn("palabras", caught.exception.message)


class TextTests(unittest.TestCase):
    def test_only_whisper_markers_are_dropped_not_bracketed_dictation(self):
        for marker in ("[BLANK_AUDIO]", "[ Silence ]", "[Music]", "[APPLAUSE]", "[Laughter]",
                       "[Inaudible]", "[_TT_120]", "[_BEG_]", "[*]", "[Speaking foreign language]"):
            self.assertTrue(is_marker(marker), marker)
        for dictation in ("[pendiente]", "[TODO: llamar a Dani]", "[1]", "[nota mental]",
                          "[BLANK_AUDIO] con texto", "corchetes [dentro] de una frase"):
            self.assertFalse(is_marker(dictation), dictation)
        self.assertEqual(clean_transcript("[BLANK_AUDIO]\n[pendiente]\n"), "[pendiente]")
        self.assertEqual(clean_transcript("apunta [pendiente] y ya"), "apunta [pendiente] y ya")

    def test_transcript_is_cleaned_up_into_one_dictation_line(self):
        self.assertEqual(clean_transcript(" Hola  mundo \n\n  segunda linea \n"), "Hola mundo segunda linea")
        self.assertEqual(clean_transcript("[BLANK_AUDIO]\n[ Silence ]\nTexto\n"), "Texto")
        self.assertEqual(clean_transcript("[MUSIC]\n[Applause]\n"), "")
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
        self.peers = {"conn-a": "100.64.0.7", "conn-a2": "100.64.0.7", "conn-b": "100.64.0.9"}
        self.rpc.host = types.SimpleNamespace(address="100.64.0.1", port=58465, peer_of=self.peers.get)

    def tearDown(self):
        self.rpc.close_attachments()
        super().tearDown()

    def call(self, params, authorized=lambda: True, connection="conn-a"):
        return self.rpc.dispatch("mobile.audio.transcribe", params, connection, authorized=authorized)

    def error(self, params, authorized=lambda: True, connection="conn-a"):
        with self.assertRaises(RPCError) as caught:
            self.call(params, authorized, connection)
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
        limit = (self.rpc.transcription.max_bytes * 4) // 3 + 16
        self.assertEqual(self.error({"audio": "A" * (limit + 1), "mime": "audio/mp4"}), "too_large")
        self.assertLess(limit + 4096, MAX_FRAME)  # Y el maximo admitido sigue cabiendo en un marco.
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

    def test_the_device_owns_its_turn_across_connections(self):
        outcomes = []
        def busy(argv, timeout):
            if outcomes:  # El dictado anidado del otro movil no vuelve a anidar.
                Path(argv[-1]).write_bytes(wav_bytes())
                return Result()
            outcomes.append(self.error(self.request(), connection="conn-a2"))  # Mismo movil, otra conexion.
            outcomes.append(self.call(self.request(), connection="conn-b")["text"])  # Otro movil: entra.
            Path(argv[-1]).write_bytes(wav_bytes())
            return Result()
        self.runner.handlers["ffmpeg"] = busy
        self.assertEqual(self.call(self.request())["text"], "Hola desde el movil")
        self.assertEqual(outcomes, ["busy", "Hola desde el movil"])
        self.assertEqual(self.rpc.transcription.running, [])

    def test_a_phone_that_disconnects_mid_transcription_cancels_the_engine(self):
        def leaves(argv, timeout):
            self.peers.pop("conn-a")  # El movil se va mientras ffmpeg trabaja.
            Path(argv[-1]).write_bytes(wav_bytes())
            return Result()
        self.runner.handlers["ffmpeg"] = leaves
        self.assertEqual(self.error(self.request()), "io_failed")
        self.assertEqual(self.runner.names(), ["ffmpeg"])  # Whisper no llega a arrancar.
        self.assertEqual(self.leftovers(), [])
        self.assertEqual(self.rpc.transcription.running, [])

    def test_a_revoked_device_cancels_the_engine_too(self):
        approved = [True]
        def revoked(argv, timeout):
            approved[0] = False  # Le quitan el permiso a media transcripcion.
            Path(argv[-1]).write_bytes(wav_bytes())
            return Result()
        self.runner.handlers["ffmpeg"] = revoked
        self.assertEqual(self.error(self.request(), authorized=lambda: approved[0]), "io_failed")
        self.assertEqual(self.runner.names(), ["ffmpeg"])
        self.assertEqual(self.leftovers(), [])

    def test_an_unknown_connection_is_not_a_device(self):
        self.assertEqual(self.error(self.request(), connection="conn-fantasma"), "not_found")

    def test_a_host_without_whisper_answers_unsupported(self):
        self.binaries.clear()
        self.rpc.transcription = self.engine()
        self.assertEqual(self.error(self.request()), "unsupported")


if __name__ == "__main__":
    unittest.main()
