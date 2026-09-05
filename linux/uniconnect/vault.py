"""Encrypted credential revisions and the macOS portable envelope format.

Keys live in the desktop Secret Service, a password-wrapped key file, or an
authenticated systemd host credential for unattended root desktop startup. No
unencrypted UniConnect key is written. ``lock`` drops this process's cached key;
it does not lock the user's desktop keyring or prevent the host administrator
from opening an automatic vault.
"""

from __future__ import annotations

import base64
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import threading
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


class VaultError(ValueError):
    """Invalid or unavailable credential storage; details never contain secrets."""


class VaultLocked(VaultError):
    """A desktop unlock or an explicitly chosen password is required."""


def default_root() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "uniconnect"


def private_read(path: Path, maximum: int = 32 * 1024 * 1024) -> bytes:
    """Read a regular owned file without following a final symlink."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise VaultError("Storage must be a regular file owned by the current user")
        if info.st_size > maximum:
            raise VaultError("Storage exceeds the supported size")
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "rb", closefd=False) as stream:
            return stream.read(maximum + 1)
    finally:
        os.close(fd)


def atomic_write(path: Path, content: bytes) -> None:
    """Commit a private file with fsync + rename + parent directory fsync."""
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.is_symlink() or path.is_symlink():
        raise VaultError("Symbolic links are not supported for private storage")
    os.chmod(path.parent, 0o700)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + "-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


_process_locks = {}
_process_locks_guard = threading.Lock()
_held_locks = threading.local()
_transaction_writers = threading.local()


@contextmanager
def private_lock(path: Path):
    """Serialize file writers across processes, with same-thread nested leases."""
    identity = (os.getpid(), str(path.absolute()))
    with _process_locks_guard:
        local = _process_locks.setdefault(identity, threading.RLock())
    with local:
        held = getattr(_held_locks, "files", None)
        if held is None:
            held = _held_locks.files = set()
        if identity in held:
            yield
            return
        with _private_file_lock(path):
            held.add(identity)
            try:
                yield
            finally:
                held.remove(identity)


@contextmanager
def _private_file_lock(path: Path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.is_symlink():
        raise VaultError("Symbolic links are not supported for private storage")
    os.chmod(path.parent, 0o700)
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise VaultError("Storage lock must be owned by the current user")
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


@contextmanager
def storage_lease(root: Path, transaction: bool = False):
    """Keep state and credential writers outside an active persistent transaction."""
    with private_lock(root / ".transaction.lock"):
        active = getattr(_transaction_writers, "roots", None)
        if active is None:
            active = _transaction_writers.roots = set()
        identity = (os.getpid(), str(root.absolute()))
        inserted = transaction and identity not in active
        if inserted:
            active.add(identity)
        try:
            yield
        finally:
            if inserted:
                active.remove(identity)


def transaction_writer_active(root: Path) -> bool:
    return (os.getpid(), str(root.absolute())) in getattr(_transaction_writers, "roots", set())


class Envelope:
    """AES-256-GCM wire format shared with UniConnectCrypto on macOS."""

    format = "uniconnect-aesgcm"
    iterations = 600_000

    @classmethod
    def parse(cls, data: bytes | dict) -> dict:
        try:
            value = data if isinstance(data, dict) else json.loads(data)
            if value.get("format") != cls.format or value.get("version") != 1:
                raise ValueError()
            for field in ("nonce", "ciphertext", "tag"):
                base64.b64decode(value[field], validate=True)
            if len(base64.b64decode(value["nonce"])) != 12 or len(base64.b64decode(value["tag"])) != 16:
                raise ValueError()
            return value
        except (ValueError, TypeError, KeyError, AttributeError):
            raise VaultError("Invalid encrypted UniConnect envelope") from None

    @classmethod
    def seal(cls, plaintext: bytes, key: bytes, kdf: dict | None = None) -> bytes:
        nonce = os.urandom(12)
        ciphertext = AESGCM(key).encrypt(nonce, plaintext, cls.format.encode())
        result = {"format": cls.format, "version": 1,
                  "nonce": base64.b64encode(nonce).decode(),
                  "ciphertext": base64.b64encode(ciphertext[:-16]).decode(),
                  "tag": base64.b64encode(ciphertext[-16:]).decode()}
        if kdf:
            result.update(kdf)
        return json.dumps(result, sort_keys=True, indent=2).encode()

    @classmethod
    def open(cls, data: bytes | dict, key: bytes) -> bytes:
        envelope = cls.parse(data)
        try:
            return AESGCM(key).decrypt(
                base64.b64decode(envelope["nonce"]),
                base64.b64decode(envelope["ciphertext"]) + base64.b64decode(envelope["tag"]),
                cls.format.encode(),
            )
        except (InvalidTag, ValueError):
            raise VaultError("Incorrect password or damaged encrypted file") from None

    @classmethod
    def _password_key(cls, password: str, envelope: dict) -> bytes:
        try:
            iterations = envelope["iterations"]
            salt = base64.b64decode(envelope["salt"], validate=True)
            if envelope.get("kdf") != "pbkdf2-sha256" or type(iterations) is not int:
                raise ValueError()
            if not 10_000 <= iterations <= 10_000_000 or not 16 <= len(salt) <= 128:
                raise ValueError()
        except (KeyError, TypeError, ValueError):
            raise VaultError("Unsupported password derivation parameters") from None
        return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations, dklen=32)

    @classmethod
    def seal_with_passphrase(cls, plaintext: bytes, passphrase: str) -> bytes:
        if not passphrase:
            raise VaultError("A nonempty password is required")
        kdf = {"kdf": "pbkdf2-sha256", "iterations": cls.iterations,
               "salt": base64.b64encode(os.urandom(16)).decode()}
        return cls.seal(plaintext, cls._password_key(passphrase, kdf), kdf)

    @classmethod
    def open_with_passphrase(cls, data: bytes | dict, passphrase: str) -> bytes:
        envelope = cls.parse(data)
        return cls.open(envelope, cls._password_key(passphrase, envelope))


class Vault:
    """A locked-by-default immutable map of credential UUIDs to SSH commands."""

    def __init__(self, root: str | Path | None = None):
        self.root = Path(root) if root is not None else default_root()
        self.path = self.root / "vault.uc"
        self.key_path = self.root / "master-key.wrap.uc"
        self.automatic_key_path = self.root / "master-key.systemd.ctl.enc"
        self._key: bytes | None = None
        self._entries: dict[str, str] | None = None

    @property
    def exists(self) -> bool:
        return self.path.exists() or self.key_path.exists() or self.automatic_key_path.exists()

    @property
    def locked(self) -> bool:
        return self._key is None

    @property
    def mode(self) -> str:
        if self.automatic_key_path.exists():
            return "systemd-creds"
        return "passphrase" if self.key_path.exists() else "secret-service"

    @staticmethod
    def automatic_unlock_available() -> bool:
        """The root-owned systemd host credential backend is installed."""
        return os.geteuid() == 0 and os.access("/usr/bin/systemd-creds", os.X_OK)

    @staticmethod
    def _systemd_creds(arguments: list[str], content: bytes | None = None) -> bytes:
        # Never inherit systemd credential overrides or put key material in argv.
        try:
            result = subprocess.run(
                ["/usr/bin/systemd-creds", *arguments], input=content,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
                timeout=20, env={"PATH": "/usr/bin:/bin", "SYSTEMD_LOG_LEVEL": "err",
                                 "SYSTEMD_COLORS": "0", "LC_ALL": "C"},
            )
        except (OSError, subprocess.TimeoutExpired):
            raise VaultError("Automatic credential protection is unavailable on this host") from None
        if result.returncode:
            raise VaultError("Automatic credential verification failed on this host")
        return result.stdout

    def _automatic_key(self, ciphertext: bytes | None = None) -> bytes:
        key = self._systemd_creds(
            ["--name=uniconnect-master", "--newline=no", "decrypt", "-", "-"],
            ciphertext if ciphertext is not None else private_read(self.automatic_key_path, 65536),
        )
        if len(key) != 32:
            raise VaultError("Invalid automatically wrapped master key")
        return key

    def _write_automatic_key(self, key: bytes) -> None:
        if not self.automatic_unlock_available():
            raise VaultError("Automatic host credential protection requires root and systemd-creds")
        self._systemd_creds(["setup"])
        ciphertext = self._systemd_creds(
            ["--with-key=host", "--name=uniconnect-master", "encrypt", "-", "-"], key,
        )
        if not ciphertext or key in ciphertext or self._automatic_key(ciphertext) != key:
            raise VaultError("Automatic master key verification failed")
        atomic_write(self.automatic_key_path, ciphertext)
        if self._automatic_key() != key:
            raise VaultError("Automatic master key read-back verification failed")

    def enable_automatic_unlock(self) -> None:
        """Wrap the current key for password-free startup on this root-owned host.

        Existing Secret Service or password-wrapped copies remain available for
        recovery. This changes key access, never credential IDs or vault contents.
        """
        self._require_unlocked()
        if self.automatic_key_path.exists():
            if self._automatic_key() != self._key:
                raise VaultError("Automatic master key conflicts with the unlocked vault")
            return
        self._write_automatic_key(self._key)

    def _desktop_key(self, create: bool = False) -> bytes:
        try:
            import gi
            gi.require_version("Secret", "1")
            from gi.repository import Secret
            schema = Secret.Schema.new("com.unixcision.uniconnect.master-key", Secret.SchemaFlags.NONE,
                                       {"storage": Secret.SchemaAttributeType.STRING})
            attributes = {"storage": str(self.root.resolve())}
            encoded = Secret.password_lookup_sync(schema, attributes, None)
            if not encoded and create:
                encoded = base64.b64encode(os.urandom(32)).decode()
                if not Secret.password_store_sync(schema, attributes, Secret.COLLECTION_DEFAULT,
                                                  "UniConnect encryption key", encoded, None):
                    raise VaultLocked("Desktop keyring could not store the key")
                if Secret.password_lookup_sync(schema, attributes, None) != encoded:
                    raise VaultLocked("Desktop keyring verification failed")
            if not encoded:
                raise VaultLocked("Unlock the desktop keyring or use a vault password")
            key = base64.b64decode(encoded, validate=True)
            if len(key) != 32:
                raise VaultError("Invalid desktop encryption key")
            return key
        except VaultError:
            raise
        except Exception:
            raise VaultLocked("Desktop Secret Service is unavailable; a vault password is required") from None

    def initialize(self, passphrase: str | None = None) -> None:
        with storage_lease(self.root):
            self._initialize(passphrase)

    def _initialize(self, passphrase: str | None = None) -> None:
        if self.exists:
            self.unlock(passphrase)
            return
        if passphrase is not None:
            if not passphrase:
                raise VaultLocked("Choose a nonempty vault password")
            key = os.urandom(32)
            atomic_write(self.key_path, Envelope.seal_with_passphrase(key, passphrase))
        elif self.automatic_unlock_available():
            key = os.urandom(32)
            self._write_automatic_key(key)
        else:
            key = self._desktop_key(create=True)
        self._key, self._entries = key, {}
        self._persist()

    def unlock(self, passphrase: str | None = None) -> None:
        with storage_lease(self.root):
            self._unlock(passphrase)

    def _unlock(self, passphrase: str | None = None) -> None:
        if not self.exists:
            self.initialize(passphrase)
            return
        if self.automatic_key_path.exists():
            # This path is deliberately noninteractive, even if GNOME is locked.
            key = self._automatic_key()
        elif self.key_path.exists():
            if passphrase is None:
                raise VaultLocked("Enter the vault password")
            key = Envelope.open_with_passphrase(private_read(self.key_path), passphrase)
            if len(key) != 32:
                raise VaultError("Invalid wrapped master key")
        else:
            # An existing ciphertext never authorizes creation of a replacement key.
            key = self._desktop_key(create=False)
        entries = self._decode_entries(Envelope.open(private_read(self.path), key)) if self.path.exists() else {}
        self._key, self._entries = key, entries

    def lock(self) -> None:
        self._entries = None
        self._key = None

    def _require_unlocked(self) -> None:
        if self.locked or self._entries is None:
            raise VaultLocked("The UniConnect vault is locked")

    @staticmethod
    def _decode_entries(content: bytes) -> dict[str, str]:
        try:
            entries = json.loads(content)
            if not isinstance(entries, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in entries.items()):
                raise ValueError()
            return {str(uuid.UUID(k)): v for k, v in entries.items()}
        except (ValueError, TypeError):
            raise VaultError("Invalid credential map") from None

    def _persist(self) -> None:
        self._require_unlocked()
        with storage_lease(self.root), private_lock(self.root / ".vault.lock"):
            journal_path = self.root / "transactions/pending.json"
            if journal_path.exists():
                try:
                    journal = json.loads(private_read(journal_path))
                except ValueError:
                    raise VaultError("A pending workspace transaction must be recovered before writing credentials") from None
                if journal.get("id") != getattr(self, "_transaction_token", None):
                    raise VaultError("A pending workspace transaction must be recovered before writing credentials")
            merged = self._decode_entries(Envelope.open(private_read(self.path), self._key)) if self.path.exists() else {}
            for key, value in self._entries.items():
                if key in merged and merged[key] != value:
                    raise VaultError("Concurrent credential revision conflict")
                merged[key] = value
            atomic_write(self.path, Envelope.seal(json.dumps(merged, sort_keys=True).encode(), self._key))
            self._entries = merged

    def seal_checkpoint(self, content: bytes) -> bytes:
        """Authenticate a private rollback or commit capsule with the current key."""
        self._require_unlocked()
        return Envelope.seal(content, self._key)

    def open_checkpoint(self, content: bytes) -> bytes:
        """Authenticate a capsule before allowing a state rollback."""
        self._require_unlocked()
        return Envelope.open(content, self._key)

    def restore_encrypted_snapshot(self, content: bytes) -> None:
        """Restore an exact authenticated vault generation, including removed revisions."""
        self._require_unlocked()
        entries = self._decode_entries(Envelope.open(content, self._key))
        with storage_lease(self.root), private_lock(self.root / ".vault.lock"):
            if not transaction_writer_active(self.root):
                raise VaultError("Exact vault rollback requires a workspace transaction")
            atomic_write(self.path, content)
            if private_read(self.path) != content:
                raise VaultError("Credential rollback read-back verification failed")
            self._entries = entries

    def get(self, credential_id: str) -> str:
        with storage_lease(self.root):
            return self._get(credential_id)

    def _get(self, credential_id: str) -> str:
        self._require_unlocked()
        try:
            return self._entries[str(uuid.UUID(credential_id))]
        except (KeyError, ValueError, TypeError):
            raise VaultError("The saved credential revision is missing") from None

    def put(self, command: str, credential_id: str | None = None) -> str:
        with storage_lease(self.root):
            return self._put(command, credential_id)

    def _put(self, command: str, credential_id: str | None = None) -> str:
        self._require_unlocked()
        if not isinstance(command, str) or not command.strip() or len(command) > 65536 or "\0" in command:
            raise VaultError("Invalid credential material")
        command = command.strip()
        if credential_id:
            credential_id = str(uuid.UUID(credential_id))
            old = self._entries.get(credential_id)
            if old is not None and old != command:
                raise VaultError("An immutable credential revision cannot be changed")
        else:
            for key, value in self._entries.items():
                if value == command:
                    return key
            credential_id = str(uuid.uuid4())
        original = dict(self._entries)
        self._entries[credential_id] = command
        try:
            self._persist()
        except Exception:
            self._entries = original
            raise
        return credential_id

    def encrypted_snapshot(self) -> bytes:
        with storage_lease(self.root):
            self._require_unlocked()
            content = private_read(self.path)
            self._decode_entries(Envelope.open(content, self._key))
            return content

    def merge_encrypted_snapshot(self, content: bytes) -> None:
        with storage_lease(self.root):
            self._merge_encrypted_snapshot(content)

    def _merge_encrypted_snapshot(self, content: bytes) -> None:
        self._require_unlocked()
        restored = self._decode_entries(Envelope.open(content, self._key))
        for key, value in restored.items():
            if key in self._entries and self._entries[key] != value:
                raise VaultError("A restored credential conflicts with an immutable revision")
        original = dict(self._entries)
        self._entries.update(restored)
        try:
            self._persist()
        except Exception:
            self._entries = original
            raise
