"""Opt-in, reversible installation of UniConnect metadata hooks for Antigravity.

Antigravity CLI only loads hooks from its global or workspace hook files and its
status line from settings.json. This module adds one namespaced hook and a
statusline only when the user's settings do not already define a statusline.
All other JSON keys are preserved; disable removes only UniConnect-owned entries.
"""

from __future__ import annotations

import base64
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import shlex
import stat
import tempfile
import zlib


HOOK_KEY = "uniconnect-native-metadata"
MARKER = "UNICONNECT_AGY_METADATA_V1"
MAX_CONFIG = 1024 * 1024


class IntegrationError(ValueError):
    """An Antigravity configuration is unsafe to edit without user review."""


class AntigravityIntegration:
    def __init__(self, *, home=None, helper_source=None):
        self.home = Path(home or Path.home()).expanduser()
        self.hooks_path = self.home / ".gemini/config/hooks.json"
        self.settings_path = self.home / ".gemini/antigravity-cli/settings.json"
        self.lock_path = self.home / ".local/state/uniconnect/antigravity-integration.lock"
        self.helper_source = (Path(helper_source) if helper_source else
                              Path(__file__).with_name("agent_identity_hook.py"))

    def _check_paths(self):
        for path in (self.home / ".gemini", self.home / ".gemini/config",
                     self.home / ".gemini/antigravity-cli"):
            if path.is_symlink():
                raise IntegrationError("symlink_config_path")
        if not self.home.is_dir() or self.home.is_symlink():
            raise IntegrationError("invalid_home")

    @contextmanager
    def _lock(self):
        self.lock_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.lock_path.parent.is_symlink() or self.lock_path.is_symlink():
            raise IntegrationError("symlink_lock_path")
        try:
            fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        except OSError as error:
            raise IntegrationError("lock_unavailable") from error
        try:
            os.fchmod(fd, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    @staticmethod
    def _read(path):
        if path.is_symlink():
            raise IntegrationError("symlink_config_path")
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        except FileNotFoundError:
            return None, None
        except OSError as error:
            raise IntegrationError("config_unreadable") from error
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_size > MAX_CONFIG:
                raise IntegrationError("unsafe_config_file")
            chunks, remaining = [], MAX_CONFIG + 1
            while remaining:
                chunk = os.read(fd, remaining)
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            raw = b"".join(chunks)
            if len(raw) > MAX_CONFIG:
                raise IntegrationError("config_too_large")
            try:
                value = json.loads(raw)
            except (ValueError, UnicodeDecodeError) as error:
                raise IntegrationError("config_invalid_json") from error
            if not isinstance(value, dict):
                raise IntegrationError("config_invalid_shape")
            return raw, (value, stat.S_IMODE(info.st_mode))
        finally:
            os.close(fd)

    @staticmethod
    def _write(path, value, mode):
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if path.parent.is_symlink() or path.is_symlink():
            raise IntegrationError("symlink_config_path")
        fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
        try:
            os.fchmod(fd, mode)
            payload = (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()
            with os.fdopen(fd, "wb") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def _command(self, mode, event=None):
        try:
            source = self.helper_source.read_bytes()
        except OSError as error:
            raise IntegrationError("helper_unavailable") from error
        if len(source) > 65536:
            raise IntegrationError("helper_too_large")
        encoded = base64.b64encode(zlib.compress(source, 9)).decode("ascii")
        bootstrap = ("import base64,sys,zlib;sys.argv=['uniconnect-agent-hook'," +
                     repr(mode) + ("," + repr(event) if event else "") +
                     "];exec(zlib.decompress(base64.b64decode(" + repr(encoded) + ")))" )
        # The marker lets disable() remove only the command we created.
        return shlex.join(["python3", "-c", bootstrap, MARKER])

    def _documents(self, *, allow_statusline_conflict=False):
        hooks_raw, hooks_read = self._read(self.hooks_path)
        settings_raw, settings_read = self._read(self.settings_path)
        hooks = hooks_read[0] if hooks_read else {}
        settings = settings_read[0] if settings_read else {}
        if "statusLine" in settings and not allow_statusline_conflict:
            statusline = settings["statusLine"]
            if not (isinstance(statusline, dict) and isinstance(statusline.get("command"), str)
                    and MARKER in statusline["command"]):
                raise IntegrationError("statusline_conflict")
        if HOOK_KEY in hooks:
            entry = hooks[HOOK_KEY]
            if not self._managed_hook(entry):
                raise IntegrationError("hook_name_conflict")
        return hooks_raw, hooks, hooks_read, settings_raw, settings, settings_read

    @staticmethod
    def _managed_hook(entry):
        expected_events = {"SessionStart", "PreInvocation", "PostInvocation", "Stop"}
        if not isinstance(entry, dict) or set(entry) != expected_events:
            return False
        for event, rows in entry.items():
            if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
                return False
            hooks = rows[0].get("hooks")
            if not isinstance(hooks, list) or len(hooks) != 1 or not isinstance(hooks[0], dict):
                return False
            hook = hooks[0]
            if (hook.get("type") != "command" or not isinstance(hook.get("command"), str)
                    or MARKER not in hook["command"] or hook.get("timeout") != 3):
                return False
        return True

    def _desired_hook(self):
        return {event: [{"hooks": [{"type": "command", "command": self._command("signal", event),
                                    "timeout": 3}]}]
                for event in ("SessionStart", "PreInvocation", "PostInvocation", "Stop")}

    def enable(self):
        self._check_paths()
        with self._lock():
            hooks_raw, hooks, hooks_read, settings_raw, settings, settings_read = self._documents()
            hooks[HOOK_KEY] = self._desired_hook()
            settings["statusLine"] = {"type": "command", "command": self._command("statusline"),
                                      "stack_with_default": True}
            # Validate every command/config before either file is modified.
            self._command("statusline")
            mode_hooks = hooks_read[1] if hooks_read else 0o600
            mode_settings = settings_read[1] if settings_read else 0o600
            written = []
            try:
                self._assert_unchanged(self.hooks_path, hooks_raw)
                self._write(self.hooks_path, hooks, mode_hooks)
                written.append((self.hooks_path, hooks_raw, mode_hooks))
                self._assert_unchanged(self.settings_path, settings_raw)
                self._write(self.settings_path, settings, mode_settings)
                written.append((self.settings_path, settings_raw, mode_settings))
            except Exception:
                # Roll back only our successful writes; never overwrite an external
                # change that raced the second-file update.
                for path, raw, mode in reversed(written):
                    self._restore(path, raw, mode)
                raise
            return {"enabled": True, "hooks": str(self.hooks_path), "settings": str(self.settings_path)}

    @staticmethod
    def _assert_unchanged(path, expected):
        current, _ = AntigravityIntegration._read(path)
        if current != expected:
            raise IntegrationError("config_changed_concurrently")

    @staticmethod
    def _restore(path, raw, mode):
        if raw is None:
            path.unlink(missing_ok=True)
        else:
            temporary = path.with_name("." + path.name + ".rollback")
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
            try:
                os.fchmod(fd, mode)
                with os.fdopen(fd, "wb") as stream:
                    stream.write(raw)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)

    def disable(self):
        self._check_paths()
        with self._lock():
            hooks_raw, hooks, hooks_read, settings_raw, settings, settings_read = self._documents(allow_statusline_conflict=True)
            changed = False
            if HOOK_KEY in hooks:
                if not self._managed_hook(hooks[HOOK_KEY]):
                    raise IntegrationError("hook_modified_by_user")
                hooks = dict(hooks)
                hooks.pop(HOOK_KEY)
                changed = True
            statusline = settings.get("statusLine")
            if statusline is not None and isinstance(statusline, dict) and MARKER in str(statusline.get("command", "")):
                settings = dict(settings)
                settings.pop("statusLine")
                changed = True
            if changed:
                written = []
                try:
                    if hooks_read:
                        self._assert_unchanged(self.hooks_path, hooks_raw)
                        self._write(self.hooks_path, hooks, hooks_read[1])
                        written.append((self.hooks_path, hooks_raw, hooks_read[1]))
                    if settings_read:
                        self._assert_unchanged(self.settings_path, settings_raw)
                        self._write(self.settings_path, settings, settings_read[1])
                        written.append((self.settings_path, settings_raw, settings_read[1]))
                except Exception:
                    for path, raw, mode in reversed(written):
                        self._restore(path, raw, mode)
                    raise
            return {"enabled": False, "changed": changed}

    def status(self):
        self._check_paths()
        _, hooks, _, _, settings, _ = self._documents(allow_statusline_conflict=True)
        hook_enabled = self._managed_hook(hooks.get(HOOK_KEY))
        line = settings.get("statusLine")
        line_enabled = isinstance(line, dict) and MARKER in str(line.get("command", ""))
        return {"enabled": hook_enabled and line_enabled, "hooks": hook_enabled, "statusLine": line_enabled}
