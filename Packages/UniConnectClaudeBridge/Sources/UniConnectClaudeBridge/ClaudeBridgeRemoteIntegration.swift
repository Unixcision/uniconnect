import Foundation

/// Renders the versioned, reversible remote hook integration for a direct SSH route.
public struct ClaudeBridgeRemoteIntegration: Sendable {
    /// Version of the on-host script and settings entry owned by UniConnect.
    public static let version = 1

    /// Creates a connection plan that uses the supplied app listener port.
    ///
    /// - Parameters:
    ///   - route: Trusted, privacy-minimized route metadata.
    ///   - installationID: Stable non-secret identifier derived by UniConnect.
    ///   - localListenerPort: Ephemeral port bound only to Mac loopback.
    /// - Returns: SSH options plus idempotent setup and cleanup commands.
    public static func connectionPlan(
        route: ClaudeBridgeRoute,
        installationID: String,
        localListenerPort: UInt16
    ) -> ClaudeBridgeConnectionPlan {
        let remotePort = remoteForwardPort(for: route.id)
        let scriptPath = "$HOME/.uniconnect/claude-bridge/v1/notify.py"
        let scriptTemporaryPath = "$HOME/.uniconnect/claude-bridge/v1/.notify.py.tmp.$$"
        let setupArguments = [
            "register",
            "--installation-id", installationID,
            "--route-id", route.id.uuidString.lowercased(),
            "--port", String(remotePort),
            "--workspace-id", route.workspaceID.uuidString.lowercased(),
            "--surface-id", route.surfaceID.uuidString.lowercased(),
            "--host-id", boundedIdentifier(route.hostLabel),
            "--tmux-session", route.tmuxSession,
        ]
        let renderedScript = pythonScript
        let setup = """
        { umask 077; mkdir -p "$HOME/.uniconnect/claude-bridge/v1" && if command -v python3 >/dev/null 2>&1; then printf '%s' \(shellQuote(renderedScript)) > "\(scriptTemporaryPath)" && chmod 700 "\(scriptTemporaryPath)" && mv -f "\(scriptTemporaryPath)" "\(scriptPath)" && "\(scriptPath)" \(shellArguments(setupArguments)); fi; } >/dev/null 2>&1 || true
        """
        return ClaudeBridgeConnectionPlan(
            routeID: route.id,
            sshOptions: [
                "-o", "ExitOnForwardFailure=yes",
                "-R", "127.0.0.1:\(remotePort):127.0.0.1:\(localListenerPort)",
            ],
            remoteSetupCommand: setup,
            remoteCleanupCommand: remoteCleanupCommand(
                routeID: route.id,
                installationID: installationID
            )
        )
    }

    /// Renders an explicit cleanup command for a route that may no longer be live locally.
    ///
    /// Unlike the best-effort setup embedded in an interactive attach, this command
    /// returns a failure status when the remote integration cannot be removed safely.
    ///
    /// - Parameters:
    ///   - routeID: Stable route UUID to remove.
    ///   - installationID: Stable non-secret UniConnect installation identifier.
    /// - Returns: A non-secret remote command suitable for a controlled SSH process.
    public static func remoteCleanupCommand(routeID: UUID, installationID: String) -> String {
        remoteCleanupCommand(routeIDs: [routeID], installationID: installationID)
    }

    /// Renders one bounded SSH cleanup command for multiple routes on the same host.
    ///
    /// The current script is transferred once, then each exact route is unregistered
    /// sequentially. This keeps command size bounded as a box gains tmux windows.
    ///
    /// - Parameters:
    ///   - routeIDs: Stable route UUIDs to remove from one credential/host.
    ///   - installationID: Stable non-secret UniConnect installation identifier.
    /// - Returns: A non-secret remote command suitable for a controlled SSH process.
    public static func remoteCleanupCommand(routeIDs: [UUID], installationID: String) -> String {
        let scriptPath = "$HOME/.uniconnect/claude-bridge/v1/notify.py"
        let temporaryPath = "$HOME/.uniconnect/claude-bridge/v1/.notify-cleanup.py.tmp.$$"
        let uniqueRouteIDs = Array(Set(routeIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueRouteIDs.isEmpty else { return "false" }
        let removals = uniqueRouteIDs.map { routeID in
            let arguments = [
                "unregister",
                "--installation-id", installationID,
                "--route-id", routeID.uuidString.lowercased(),
            ]
            return "\"\(scriptPath)\" \(shellArguments(arguments))"
        }.joined(separator: " && ")
        return "{ umask 077; command -v python3 >/dev/null 2>&1 && mkdir -p \"$HOME/.uniconnect/claude-bridge/v1\" && printf '%s' \(shellQuote(pythonScript)) > \"\(temporaryPath)\" && chmod 700 \"\(temporaryPath)\" && mv -f \"\(temporaryPath)\" \"\(scriptPath)\" && \(removals); } >/dev/null 2>&1"
    }

    /// Chooses a stable high remote port from a route UUID.
    ///
    /// The route UUID is unique per terminal window, avoiding clashes between boxes
    /// and hosts while keeping reconnection deterministic.
    ///
    /// - Parameter routeID: Stable route UUID.
    /// - Returns: A port in the unprivileged range `42000...61999`.
    public static func remoteForwardPort(for routeID: UUID) -> UInt16 {
        let bytes = withUnsafeBytes(of: routeID.uuid) { Array($0) }
        let value = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return 42_000 + value % 20_000
    }

    private static func boundedIdentifier(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:@-")
        let filtered = value.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(filtered)).prefix(160)
        return result.isEmpty ? "remote" : String(result)
    }

    private static func shellArguments(_ arguments: [String]) -> String {
        arguments.map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Python 3 is intentionally the only remote dependency. The handler accepts at
    // most 64 KiB from Claude, parses it in memory, and constructs a new allow-listed
    // envelope. It never forwards the input JSON, prompt, response, transcript, or env.
    private static let pythonScript = #"""
#!/usr/bin/env python3
import argparse
import base64
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import shlex
import socket
import subprocess
import sys
import time

PROTOCOL = "uniconnect-claude-bridge"
VERSION = 1
ROOT = os.path.expanduser("~/.uniconnect/claude-bridge/v1")
INSTALLATIONS = os.path.join(ROOT, "installations")
BACKUPS = os.path.join(ROOT, "backups")
SETTINGS_STATE = os.path.join(ROOT, "settings-state.json")
SETTINGS = os.path.expanduser("~/.claude/settings.json")
SCRIPT = os.path.join(ROOT, "notify.py")
MAX_HOOK_INPUT = 65536
MAX_FRAME = 16384
MAX_SETTINGS = 4 * 1024 * 1024
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
ID_RE = UUID_RE
CORRELATION_RE = re.compile(r"^[0-9a-f]{64}$")
INSTALL_RE = re.compile(r"^[0-9a-f]{32}$")
PANE_RE = re.compile(r"^%[0-9]{1,12}$")


def atomic_write(path, data, mode):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    temporary = path + ".tmp." + secrets.token_hex(8)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def bounded_read(path, maximum):
    with open(path, "rb") as source:
        data = source.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("file_too_large")
    return data


def hook_command(kind):
    return shlex.quote(SCRIPT) + " hook " + kind


def owned_command(value):
    return isinstance(value, str) and value in (
        hook_command("stop"),
        hook_command("notification"),
        hook_command("prompt"),
        hook_command("session-start"),
    )


class JsonNode:
    def __init__(self, kind, start, end, members=None, elements=None):
        self.kind = kind
        self.start = start
        self.end = end
        self.members = members or []
        self.elements = elements or []


class JsonLayoutParser:
    def __init__(self, text):
        self.text = text
        self.index = 0

    def parse(self):
        self.skip_space()
        node = self.parse_value()
        self.skip_space()
        if self.index != len(self.text):
            raise ValueError("trailing_json")
        return node

    def skip_space(self):
        while self.index < len(self.text) and self.text[self.index] in " \t\r\n":
            self.index += 1

    def parse_value(self):
        self.skip_space()
        if self.index >= len(self.text):
            raise ValueError("missing_value")
        value = self.text[self.index]
        if value == "{":
            return self.parse_object()
        if value == "[":
            return self.parse_array()
        if value == '"':
            start = self.index
            self.parse_string()
            return JsonNode("string", start, self.index)
        start = self.index
        while self.index < len(self.text) and self.text[self.index] not in ",]} \t\r\n":
            self.index += 1
        if start == self.index:
            raise ValueError("invalid_value")
        return JsonNode("literal", start, self.index)

    def parse_string(self):
        if self.text[self.index] != '"':
            raise ValueError("missing_string")
        start = self.index
        self.index += 1
        escaped = False
        while self.index < len(self.text):
            value = self.text[self.index]
            self.index += 1
            if escaped:
                escaped = False
            elif value == "\\":
                escaped = True
            elif value == '"':
                return json.loads(self.text[start:self.index])
        raise ValueError("unterminated_string")

    def parse_object(self):
        start = self.index
        self.index += 1
        members = []
        self.skip_space()
        if self.index < len(self.text) and self.text[self.index] == "}":
            self.index += 1
            return JsonNode("object", start, self.index, members=members)
        while True:
            self.skip_space()
            member_start = self.index
            key = self.parse_string()
            self.skip_space()
            if self.index >= len(self.text) or self.text[self.index] != ":":
                raise ValueError("missing_colon")
            self.index += 1
            value = self.parse_value()
            members.append((key, value, member_start, value.end))
            self.skip_space()
            if self.index < len(self.text) and self.text[self.index] == ",":
                self.index += 1
                continue
            if self.index < len(self.text) and self.text[self.index] == "}":
                self.index += 1
                return JsonNode("object", start, self.index, members=members)
            raise ValueError("invalid_object")

    def parse_array(self):
        start = self.index
        self.index += 1
        elements = []
        self.skip_space()
        if self.index < len(self.text) and self.text[self.index] == "]":
            self.index += 1
            return JsonNode("array", start, self.index, elements=elements)
        while True:
            elements.append(self.parse_value())
            self.skip_space()
            if self.index < len(self.text) and self.text[self.index] == ",":
                self.index += 1
                continue
            if self.index < len(self.text) and self.text[self.index] == "]":
                self.index += 1
                return JsonNode("array", start, self.index, elements=elements)
            raise ValueError("invalid_array")


def parsed_layout(text):
    decoded = json.loads(text)
    root = JsonLayoutParser(text).parse()
    if not isinstance(decoded, dict) or root.kind != "object":
        raise ValueError("settings_root")
    return decoded, root


def unique_member(node, key):
    matches = [member for member in node.members if member[0] == key]
    if len(matches) > 1:
        raise ValueError("duplicate_key")
    return matches[0] if matches else None


def insertion_style(text, node):
    body = text[node.start + 1:node.end - 1]
    newline = "\r\n" if "\r\n" in text else "\n"
    multiline = "\n" in body or "\r" in body
    closing_line = max(text.rfind("\n", 0, node.end - 1), text.rfind("\r", 0, node.end - 1))
    closing_indent = text[closing_line + 1:node.end - 1]
    if not closing_indent.isspace() and closing_indent != "":
        closing_indent = ""
    children = node.members if node.kind == "object" else node.elements
    child_indent = closing_indent + "  "
    if children:
        first_start = children[0][2] if node.kind == "object" else children[0].start
        first_line = max(text.rfind("\n", 0, first_start), text.rfind("\r", 0, first_start))
        candidate = text[first_line + 1:first_start]
        if candidate.isspace() or candidate == "":
            child_indent = candidate
    return multiline, newline, closing_indent, child_indent


def content_end(text, node):
    result = node.end - 1
    while result > node.start + 1 and text[result - 1] in " \t\r\n":
        result -= 1
    return result


def append_object_member(text, node, key, rendered_value):
    if node.kind != "object":
        raise ValueError("not_object")
    position = content_end(text, node)
    multiline, newline, _, child_indent = insertion_style(text, node)
    prefix = "," if node.members else ""
    separator = newline + child_indent if multiline else (" " if node.members else "")
    addition = prefix + separator + json.dumps(key) + (": " if multiline else ":") + rendered_value
    return text[:position] + addition + text[position:]


def append_array_element(text, node, rendered_value):
    if node.kind != "array":
        raise ValueError("not_array")
    position = content_end(text, node)
    multiline, newline, _, child_indent = insertion_style(text, node)
    prefix = "," if node.elements else ""
    separator = newline + child_indent if multiline else (" " if node.elements else "")
    return text[:position] + prefix + separator + rendered_value + text[position:]


def array_element_removal(text, node, index):
    element = node.elements[index]
    if len(node.elements) == 1:
        return element.start, element.end
    if index < len(node.elements) - 1:
        return element.start, node.elements[index + 1].start
    previous = node.elements[index - 1]
    comma = text.find(",", previous.end, element.start)
    if comma < 0:
        raise ValueError("missing_array_comma")
    return comma, element.end


def first_owned_hook_removal(text):
    document, root = parsed_layout(text)
    hooks_member = unique_member(root, "hooks")
    if hooks_member is None:
        return None
    hooks_document = document.get("hooks")
    hooks_node = hooks_member[1]
    if not isinstance(hooks_document, dict) or hooks_node.kind != "object":
        raise ValueError("invalid_hooks")
    for event_name in ("Stop", "Notification", "UserPromptSubmit", "SessionStart"):
        event_member = unique_member(hooks_node, event_name)
        groups = hooks_document.get(event_name)
        if event_member is None:
            continue
        groups_node = event_member[1]
        if not isinstance(groups, list) or groups_node.kind != "array" or len(groups) != len(groups_node.elements):
            raise ValueError("invalid_hook_groups")
        for group_index, group in enumerate(groups):
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                continue
            commands = group["hooks"]
            owned_indexes = [
                index for index, command in enumerate(commands)
                if isinstance(command, dict) and owned_command(command.get("command"))
            ]
            if not owned_indexes:
                continue
            if len(owned_indexes) == len(commands) and group == expected_hook_group(event_name):
                return array_element_removal(text, groups_node, group_index)
            group_node = groups_node.elements[group_index]
            if group_node.kind != "object":
                raise ValueError("invalid_hook_group")
            commands_member = unique_member(group_node, "hooks")
            if commands_member is None or commands_member[1].kind != "array":
                raise ValueError("invalid_hook_commands")
            commands_node = commands_member[1]
            if len(commands) != len(commands_node.elements):
                raise ValueError("invalid_hook_commands")
            return array_element_removal(text, commands_node, owned_indexes[0])
    return None


def remove_owned_hooks(text):
    changed = False
    while True:
        edit = first_owned_hook_removal(text)
        if edit is None:
            return text, changed
        start, end = edit
        text = text[:start] + text[end:]
        parsed_layout(text)
        changed = True


def expected_hook_group(event_name):
    if event_name == "Stop":
        matcher, kind = "", "stop"
    elif event_name == "Notification":
        matcher, kind = "idle_prompt", "notification"
    elif event_name == "UserPromptSubmit":
        matcher, kind = "", "prompt"
    elif event_name == "SessionStart":
        matcher, kind = "", "session-start"
    else:
        return None
    return {
        "matcher": matcher,
        "hooks": [{
            "type": "command",
            "command": hook_command(kind),
            "timeout": 5,
            "async": True,
        }],
    }


def hooks_are_current(document):
    hooks = document.get("hooks")
    if not isinstance(hooks, dict):
        return False
    found = []
    for event_name, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                continue
            owned = [
                command for command in group["hooks"]
                if isinstance(command, dict) and owned_command(command.get("command"))
            ]
            if not owned:
                continue
            expected = expected_hook_group(event_name)
            if len(owned) != 1 or expected is None or group != expected:
                return False
            found.append(event_name)
    return sorted(found) == ["Notification", "SessionStart", "Stop", "UserPromptSubmit"]


def ensure_hook(text, event_name, matcher, kind):
    document, root = parsed_layout(text)
    hooks_member = unique_member(root, "hooks")
    if hooks_member is None:
        text = append_object_member(text, root, "hooks", "{}")
        document, root = parsed_layout(text)
        hooks_member = unique_member(root, "hooks")
    hooks_document = document.get("hooks")
    hooks_node = hooks_member[1]
    if not isinstance(hooks_document, dict) or hooks_node.kind != "object":
        raise ValueError("invalid_hooks")
    event_member = unique_member(hooks_node, event_name)
    if event_member is None:
        text = append_object_member(text, hooks_node, event_name, "[]")
        document, root = parsed_layout(text)
        hooks_member = unique_member(root, "hooks")
        hooks_document = document["hooks"]
        hooks_node = hooks_member[1]
        event_member = unique_member(hooks_node, event_name)
    groups = hooks_document.get(event_name)
    groups_node = event_member[1]
    if not isinstance(groups, list) or groups_node.kind != "array":
        raise ValueError("invalid_hook_groups")
    group = {
        "matcher": matcher,
        "hooks": [{
            "type": "command",
            "command": hook_command(kind),
            "timeout": 5,
            "async": True,
        }],
    }
    rendered = json.dumps(group, ensure_ascii=False, separators=(",", ":"))
    return append_array_element(text, groups_node, rendered)


def read_settings_bytes():
    if not os.path.exists(SETTINGS):
        return b""
    data = bounded_read(SETTINGS, MAX_SETTINGS)
    if len(data) > MAX_SETTINGS:
        raise ValueError("settings_too_large")
    return data


def settings_mode():
    try:
        return os.stat(SETTINGS).st_mode & 0o777
    except FileNotFoundError:
        return 0o600


def backup_settings(original):
    os.makedirs(BACKUPS, mode=0o700, exist_ok=True)
    if original:
        digest = hashlib.sha256(original).hexdigest()
        backup = os.path.join(BACKUPS, "settings-" + digest + ".json")
        if not os.path.exists(backup):
            atomic_write(backup, original, 0o600)
        return backup
    return None


def load_settings_state():
    try:
        state = json.loads(bounded_read(SETTINGS_STATE, 16 * 1024).decode("utf-8"))
        return state if isinstance(state, dict) and state.get("version") == 1 else None
    except Exception:
        return None


def save_settings_state(state):
    atomic_write(
        SETTINGS_STATE,
        (json.dumps(state, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"),
        0o600,
    )


def install_hooks():
    try:
        settings_existed = os.path.exists(SETTINGS)
        original = read_settings_bytes()
        original_text = original.decode("utf-8") if settings_existed else "{}\n"
        document, _ = parsed_layout(original_text)
        state = load_settings_state()
        original_digest = hashlib.sha256(original).hexdigest()
        if (state and state.get("installed_sha256") != original_digest
                and not (state.get("safe_restore") is True and state.get("base_sha256") == original_digest)):
            state["safe_restore"] = False
        if hooks_are_current(document):
            return True, None

        rendered, _ = remove_owned_hooks(original_text)
        rendered = ensure_hook(rendered, "Stop", "", "stop")
        rendered = ensure_hook(rendered, "Notification", "idle_prompt", "notification")
        rendered = ensure_hook(rendered, "UserPromptSubmit", "", "prompt")
        rendered = ensure_hook(rendered, "SessionStart", "", "session-start")
        rendered_bytes = rendered.encode("utf-8")
        if rendered_bytes == original:
            return True, None

        if state is None:
            backup = backup_settings(original)
            state = {
                "version": 1,
                "base_missing": not settings_existed,
                "base_sha256": original_digest,
                "base_backup": os.path.basename(backup) if backup else None,
                "base_mode": settings_mode(),
                "safe_restore": True,
            }
        state["installed_sha256"] = hashlib.sha256(rendered_bytes).hexdigest()
        save_settings_state(state)
        atomic_write(SETTINGS, rendered_bytes, settings_mode())
        return True, None
    except (UnicodeError, ValueError, json.JSONDecodeError):
        return False, "settings_invalid"
    except Exception:
        return False, "settings_write_failed"


def restore_unchanged_settings(state):
    if state.get("base_missing") is True:
        try:
            os.unlink(SETTINGS)
        except FileNotFoundError:
            pass
        return True
    backup_name = state.get("base_backup")
    base_digest = state.get("base_sha256")
    if not isinstance(backup_name, str) or os.path.basename(backup_name) != backup_name:
        return False
    try:
        original = bounded_read(os.path.join(BACKUPS, backup_name), MAX_SETTINGS)
        if hashlib.sha256(original).hexdigest() != base_digest:
            return False
        atomic_write(SETTINGS, original, int(state.get("base_mode", 0o600)) & 0o777)
        return True
    except Exception:
        return False


def uninstall_hooks_if_unused():
    for _, _, files in os.walk(INSTALLATIONS):
        if any(name.endswith(".route.json") for name in files):
            return True
    try:
        original = read_settings_bytes()
        if not original:
            try:
                os.unlink(SETTINGS_STATE)
            except FileNotFoundError:
                pass
            return True
        state = load_settings_state()
        digest = hashlib.sha256(original).hexdigest()
        if state and state.get("safe_restore") is True and state.get("installed_sha256") == digest:
            if not restore_unchanged_settings(state):
                return False
        else:
            rendered, changed = remove_owned_hooks(original.decode("utf-8"))
            if changed:
                atomic_write(SETTINGS, rendered.encode("utf-8"), settings_mode())
        try:
            os.unlink(SETTINGS_STATE)
        except FileNotFoundError:
            pass
        return True
    except Exception:
        return False


def route_directory(installation_id):
    return os.path.join(INSTALLATIONS, installation_id)


def route_paths(installation_id, route_id):
    base = os.path.join(route_directory(installation_id), route_id)
    return base + ".route.json", base + ".token"


def session_path(installation_id, route_id):
    return os.path.join(route_directory(installation_id), route_id + ".session.json")


def session_lock_path(installation_id, route_id):
    return os.path.join(route_directory(installation_id), route_id + ".session.lock")


def canonical(message):
    fields = [
        message.get("protocol", ""),
        str(message.get("version", "")),
        message.get("message", ""),
        message.get("route_id", "").lower(),
        message.get("event_id", "").lower(),
        str(message.get("timestamp_ms", "")),
        message.get("event_type") or "",
        base64.b64encode((message.get("session_id") or "").encode("utf-8")).decode("ascii"),
        base64.b64encode((message.get("cwd") or "").encode("utf-8")).decode("ascii"),
        message.get("tmux_pane") or "",
        "1" if message.get("integration_ready") is True else ("0" if message.get("integration_ready") is False else ""),
        message.get("integration_error") or "",
    ]
    return "\n".join(fields).encode("utf-8")


def send_message(port, message, token=None):
    if token is not None:
        message["signature"] = hmac.new(token, canonical(message), hashlib.sha256).hexdigest()
    payload = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
    if len(payload) > MAX_FRAME:
        return False
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.75) as connection:
            connection.settimeout(0.75)
            connection.sendall(payload)
            response = b""
            while len(response) <= 4096 and not response.endswith(b"\n"):
                chunk = connection.recv(1024)
                if not chunk:
                    break
                response += chunk
        parsed = json.loads(response.decode("utf-8"))
        return parsed.get("accepted") is True or parsed.get("duplicate") is True
    except Exception:
        return False


def register(args):
    if not INSTALL_RE.fullmatch(args.installation_id) or not ID_RE.fullmatch(args.route_id):
        return 0
    ready, error_code = install_hooks()
    directory = route_directory(args.installation_id)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    route_path, token_path = route_paths(args.installation_id, args.route_id)
    try:
        token = bounded_read(token_path, 32) if os.path.exists(token_path) else secrets.token_bytes(32)
        if len(token) != 32:
            token = secrets.token_bytes(32)
        atomic_write(token_path, token, 0o600)
        route = {
            "installation_id": args.installation_id,
            "route_id": args.route_id.lower(),
            "port": args.port,
            "workspace_id": args.workspace_id.lower(),
            "surface_id": args.surface_id.lower(),
            "host_id": args.host_id[:160],
            "tmux_session": args.tmux_session[:160],
            "updated_at_ms": int(time.time() * 1000),
        }
        atomic_write(
            route_path,
            (json.dumps(route, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"),
            0o600,
        )
        enrollment = {
            "protocol": PROTOCOL,
            "version": VERSION,
            "message": "enroll",
            "route_id": args.route_id.lower(),
            "event_id": secrets.token_hex(32),
            "timestamp_ms": int(time.time() * 1000),
            "token": base64.b64encode(token).decode("ascii"),
            "integration_ready": ready,
        }
        if error_code:
            enrollment["integration_error"] = error_code
        send_message(args.port, enrollment)
    except Exception:
        pass
    return 0


def unregister(args):
    if not INSTALL_RE.fullmatch(args.installation_id) or not ID_RE.fullmatch(args.route_id):
        return 2
    route_path, token_path = route_paths(args.installation_id, args.route_id)
    lock_path = session_lock_path(args.installation_id, args.route_id)
    failed = False
    try:
        os.makedirs(route_directory(args.installation_id), mode=0o700, exist_ok=True)
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        with os.fdopen(descriptor, "a+b") as lock:
            os.chmod(lock_path, 0o600)
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            for path in (route_path, token_path, session_path(args.installation_id, args.route_id)):
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass
                except Exception:
                    failed = True
    except Exception:
        failed = True
    try:
        os.unlink(lock_path)
    except FileNotFoundError:
        pass
    except Exception:
        failed = True
    try:
        os.rmdir(route_directory(args.installation_id))
    except OSError:
        pass
    if not uninstall_hooks_if_unused():
        failed = True
    return 1 if failed else 0


def current_tmux_session(pane):
    if not PANE_RE.fullmatch(pane):
        return None
    try:
        result = subprocess.run(
            ["tmux", "display-message", "-p", "-t", pane, "#{session_name}"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=0.5,
            check=False,
            text=True,
        )
        value = result.stdout.strip()
        return value[:160] if result.returncode == 0 and value else None
    except Exception:
        return None


def candidate_routes(tmux_session):
    candidates = []
    try:
        for installation in os.scandir(INSTALLATIONS):
            if not installation.is_dir(follow_symlinks=False) or not INSTALL_RE.fullmatch(installation.name):
                continue
            for item in os.scandir(installation.path):
                if not item.is_file(follow_symlinks=False) or not item.name.endswith(".route.json"):
                    continue
                try:
                    route = json.loads(bounded_read(item.path, 16 * 1024).decode("utf-8"))
                    if route.get("tmux_session") != tmux_session:
                        continue
                    route_id = route.get("route_id", "")
                    if not ID_RE.fullmatch(route_id):
                        continue
                    _, token_path = route_paths(installation.name, route_id)
                    token = bounded_read(token_path, 32)
                    if len(token) != 32:
                        continue
                    port = int(route.get("port", 0))
                    if port < 1 or port > 65535:
                        continue
                    candidates.append((int(route.get("updated_at_ms", 0)), route, token))
                except Exception:
                    continue
    except Exception:
        return []
    return sorted(candidates, key=lambda value: value[0], reverse=True)


def normalized_session_id(value, pane, cwd):
    value = str(value or "").strip()
    if value and len(value.encode("utf-8")) <= 160 and "\x00" not in value:
        if UUID_RE.fullmatch(value):
            return value.lower()
        if CORRELATION_RE.fullmatch(value.lower()):
            return value.lower()
        return hashlib.sha256(value.encode("utf-8")).hexdigest()
    return hashlib.sha256((pane + "\x00" + cwd).encode("utf-8")).hexdigest()


def normalized_prompt_correlation(value):
    value = str(value or "").strip()
    if not value or len(value.encode("utf-8")) > 160 or "\x00" in value:
        return None
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def persist_session_record(
    route,
    session_id,
    cwd,
    pane,
    activity_state,
    prompt_correlation,
    timestamp_ms,
):
    installation_id = route.get("installation_id", "")
    route_id = route.get("route_id", "")
    if not INSTALL_RE.fullmatch(installation_id) or not ID_RE.fullmatch(route_id):
        return False
    try:
        path = session_path(installation_id, route_id)
        lock_path = session_lock_path(installation_id, route_id)
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        with os.fdopen(descriptor, "a+b") as lock:
            os.chmod(lock_path, 0o600)
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            route_path, token_path = route_paths(installation_id, route_id)
            if not os.path.exists(route_path) or not os.path.exists(token_path):
                return False
            current = None
            try:
                current = json.loads(bounded_read(path, 16 * 1024).decode("utf-8"))
            except FileNotFoundError:
                pass
            except Exception:
                return False
            if isinstance(current, dict):
                current_timestamp = current.get("observed_at_ms", 0)
                if isinstance(current_timestamp, int) and current_timestamp > timestamp_ms:
                    return False
                current_prompt = current.get("prompt_correlation")
                if (activity_state == "idle" and current.get("activity_state") == "running"
                        and isinstance(current_prompt, str)
                        and current_prompt != prompt_correlation):
                    return False
            record = {
                "version": 1,
                "route_id": route_id.lower(),
                "session_id": session_id,
                "session_kind": "uuid" if UUID_RE.fullmatch(session_id) else "correlation",
                "cwd": cwd,
                "tmux_pane": pane,
                "activity_state": activity_state,
                "observed_at_ms": timestamp_ms,
            }
            if prompt_correlation is not None:
                record["prompt_correlation"] = prompt_correlation
            atomic_write(
                path,
                (json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"),
                0o600,
            )
            return True
    except Exception:
        return False


def hook(kind):
    try:
        raw = sys.stdin.buffer.read(MAX_HOOK_INPUT + 1)
        if not raw or len(raw) > MAX_HOOK_INPUT:
            return 0
        source = json.loads(raw.decode("utf-8"))
        if not isinstance(source, dict):
            return 0
        hook_name = source.get("hook_event_name")
        if kind == "stop":
            if hook_name != "Stop":
                return 0
            event_type = "stop"
            activity_state = "idle"
        elif kind == "notification":
            if hook_name != "Notification" or source.get("notification_type") != "idle_prompt":
                return 0
            event_type = "idle_prompt"
            activity_state = "idle"
        elif kind == "prompt":
            if hook_name != "UserPromptSubmit":
                return 0
            event_type = "user_prompt_submit"
            activity_state = "running"
        elif kind == "session-start":
            if hook_name != "SessionStart":
                return 0
            event_type = "session_start"
            activity_state = "running"
        else:
            return 0
        pane = os.environ.get("TMUX_PANE", "").strip()
        tmux_session = current_tmux_session(pane)
        cwd = str(source.get("cwd") or "").strip()
        if (not tmux_session or not cwd.startswith("/") or len(cwd.encode("utf-8")) > 4096
                or any(ord(character) < 32 or ord(character) == 127 for character in cwd)):
            return 0
        session_id = normalized_session_id(source.get("session_id"), pane, cwd)
        prompt_correlation = normalized_prompt_correlation(source.get("prompt_id"))
        timestamp_ms = int(time.time() * 1000)
        candidates = candidate_routes(tmux_session)
        if not candidates:
            return 0
        _, route, token = candidates[0]
        if not persist_session_record(
            route,
            session_id,
            cwd,
            pane,
            activity_state,
            prompt_correlation,
            timestamp_ms,
        ):
            return 0
        message = {
            "protocol": PROTOCOL,
            "version": VERSION,
            "message": "event",
            "route_id": route["route_id"],
            "event_id": secrets.token_hex(32),
            "timestamp_ms": timestamp_ms,
            "event_type": event_type,
            "session_id": session_id,
            "cwd": cwd,
            "tmux_pane": pane,
        }
        send_message(route["port"], message, token=token)
    except Exception:
        pass
    return 0


def parser():
    result = argparse.ArgumentParser(add_help=False)
    commands = result.add_subparsers(dest="command", required=True)
    registration = commands.add_parser("register", add_help=False)
    registration.add_argument("--installation-id", required=True)
    registration.add_argument("--route-id", required=True)
    registration.add_argument("--port", required=True, type=int)
    registration.add_argument("--workspace-id", required=True)
    registration.add_argument("--surface-id", required=True)
    registration.add_argument("--host-id", required=True)
    registration.add_argument("--tmux-session", required=True)
    removal = commands.add_parser("unregister", add_help=False)
    removal.add_argument("--installation-id", required=True)
    removal.add_argument("--route-id", required=True)
    hook_parser = commands.add_parser("hook", add_help=False)
    hook_parser.add_argument("kind", choices=("stop", "notification", "prompt", "session-start"))
    return result


def main():
    try:
        args = parser().parse_args()
        if args.command == "register":
            if args.port < 1 or args.port > 65535:
                return 0
            return register(args)
        if args.command == "unregister":
            return unregister(args)
        if args.command == "hook":
            return hook(args.kind)
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
"""#
}
