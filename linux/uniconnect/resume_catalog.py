"""Decoder for CMUXAgentLaunch's shared resume catalogue, including its no-prompt policy.

The same resource drives the Mac (AgentResumeArgv / AgentNoPromptPolicy) and Linux:
the resume template of each provider, its ``displayName`` and ``noPrompt``, the flags
that relaunch it without permission questions (contracts/agent-tree-v1/LEEME.md).
Linux never keeps a copy of that policy; captured provider arguments are never
persisted, only the validated window fields.

``AgentResumeCatalog.apply_policy`` is the only Linux implementation of the rule: the
self-contained relaunch worker receives this module's source in front of its own
(RelaunchAgents) and calls the very same function on the destination host.
"""

import json
from pathlib import Path
import re


class AgentResumeCatalog:
    NO_PROMPT_KEYS = ("prefix", "suffix", "legacy", "rootEnvironment", "supersedes")

    def __init__(self, resource=None):
        self.resource = Path(resource) if resource is not None else (
            Path(__file__).resolve().parents[2] / "Packages/CMUXAgentLaunch/Sources/CMUXAgentLaunch/Resources/agent-resume-v1.json"
        )
        data = json.loads(self.resource.read_text(encoding="utf-8"))
        if data.get("schemaVersion") != 1 or not isinstance(data.get("providers"), dict) or not data["providers"]:
            raise ValueError("invalid_agent_catalog")
        self.providers = data["providers"]
        identifiers = set(self.providers)
        self.aliases = {}
        for kind, provider in self.providers.items():
            tokens = provider.get("resume", [])
            if (not provider.get("executable") or not tokens or tokens[0] != "{executable}"
                    or any(tokens.count(token) != 1 for token in ("{executable}", "{sessionId}", "{arguments}"))
                    or any(not isinstance(token, str) or "\0" in token or
                           ("{" in token and token not in ("{executable}", "{sessionId}", "{arguments}")) for token in tokens)):
                raise ValueError("invalid_agent_catalog")
            for alias in provider.get("aliases", []):
                if not alias or alias in identifiers:
                    raise ValueError("invalid_agent_catalog")
                identifiers.add(alias)
                self.aliases[alias] = kind
            for option in provider.get("windowOptions", []):
                if option.get("field") not in ("cwd", "model") or not option.get("option", "").startswith("-"):
                    raise ValueError("invalid_agent_catalog")
            name = provider.get("displayName")
            if name is not None and (not isinstance(name, str) or not name.strip() or "\0" in name):
                raise ValueError("invalid_agent_catalog")
            self._validate_no_prompt(provider.get("noPrompt"))

    @classmethod
    def _validate_no_prompt(cls, policy):
        """Same shape the Mac accepts: flag lists and a root-only, shell-safe environment."""
        if policy is None:
            return
        if not isinstance(policy, dict) or not policy or any(key not in cls.NO_PROMPT_KEYS for key in policy):
            raise ValueError("invalid_agent_catalog")
        for key in ("prefix", "suffix", "legacy"):
            flags = policy.get(key, [])
            if not isinstance(flags, list) or any(
                    not isinstance(flag, str) or not re.fullmatch(r"-[A-Za-z0-9][A-Za-z0-9_=.-]*|--[A-Za-z0-9][A-Za-z0-9_=.-]*", flag)
                    for flag in flags) or len(set(flags)) != len(flags):
                raise ValueError("invalid_agent_catalog")
        environment = policy.get("rootEnvironment", {})
        if not isinstance(environment, dict) or any(
                not isinstance(name, str) or not re.fullmatch(r"[A-Z_][A-Z0-9_]*", name)
                or not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.:/-]*", value)
                for name, value in environment.items()):
            raise ValueError("invalid_agent_catalog")
        # Banderas que el modo sin preguntas sustituye y que la CLI rechaza junto a él (D2).
        superseded = policy.get("supersedes", [])
        known = set(policy.get("prefix", [])) | set(policy.get("suffix", [])) | set(policy.get("legacy", []))
        if not isinstance(superseded, list) or any(
                not isinstance(item, dict) or set(item) != {"flag", "takesValue"}
                or not isinstance(item["flag"], str) or not re.fullmatch(r"--?[A-Za-z0-9][A-Za-z0-9-]*", item["flag"])
                or not isinstance(item["takesValue"], bool) or item["flag"] in known
                for item in superseded):
            raise ValueError("invalid_agent_catalog")
        if len({item["flag"] for item in superseded}) != len(superseded):
            raise ValueError("invalid_agent_catalog")

    def canonical(self, kind):
        return self.aliases.get(kind, kind)

    def provider(self, kind):
        return self.providers[self.canonical(kind)]

    def display_name(self, kind):
        """``displayName`` of the provider in the catalogue; its id as given when it has none."""
        try:
            name = self.provider(kind).get("displayName")
        except KeyError:
            return kind
        return name if isinstance(name, str) and name.strip() else kind

    def no_prompt(self, kind):
        """The provider's no-prompt policy (a copy), or None when the catalogue has none (grok)."""
        policy = self.provider(kind).get("noPrompt")
        if policy is None:
            return None
        return {"prefix": list(policy.get("prefix", [])), "suffix": list(policy.get("suffix", [])),
                "legacy": list(policy.get("legacy", [])), "rootEnvironment": dict(policy.get("rootEnvironment", {})),
                "supersedes": [dict(item) for item in policy.get("supersedes", [])]}

    @staticmethod
    def apply_policy(policy, argv):
        """The one no-prompt rule (contracts/agent-tree-v1/LEEME.md), shared with the relaunch worker.

        Walks ``argv[1:]`` left to right: drops every prefix/suffix/legacy token, every
        ``supersedes`` flag (with its value when it takes one, also as ``--flag=value`` or
        ``-f=value``) and keeps the rest in order. Result: argv[0] + prefix + rest + suffix.
        Applying it twice gives the same argv. ``policy`` None (grok) leaves argv as it is.
        """
        if not policy or not argv:
            return list(argv)
        known = set(policy.get("prefix", [])) | set(policy.get("suffix", [])) | set(policy.get("legacy", []))
        superseded = {item["flag"]: bool(item.get("takesValue")) for item in policy.get("supersedes", [])}
        rest, index = [], 1
        while index < len(argv):
            argument = argv[index]
            flag, separator, _ = argument.partition("=")
            if argument in known:
                index += 1
            elif argument in superseded:
                index += 2 if superseded[argument] else 1
            elif separator and superseded.get(flag):
                index += 1
            else:
                rest.append(argument)
                index += 1
        return [argv[0], *policy.get("prefix", []), *rest, *policy.get("suffix", [])]

    def apply_no_prompt(self, kind, argv):
        """Remove earlier policy flags, put prefix right after argv[0] and suffix at the end, once."""
        return self.apply_policy(self.no_prompt(kind), argv)

    def resume_argv(self, kind, session_id, arguments=(), *, executable=None):
        provider = self.provider(kind)
        substitutions = {"{executable}": [executable or provider["executable"]],
                         "{sessionId}": [session_id], "{arguments}": list(arguments)}
        return [arg for token in provider["resume"] for arg in substitutions.get(token, [token])]

    def no_prompt_resume(self, kind, session_id, as_root, arguments=()):
        """(argv, env) that resumes ``session_id`` without questions; env only when running as root."""
        argv = self.apply_no_prompt(kind, self.resume_argv(kind, session_id, arguments))
        policy = self.no_prompt(kind)
        environment = dict(policy["rootEnvironment"]) if policy and as_root else {}
        return argv, environment

    @staticmethod
    def shell_command(argv, environment=None, cwd=None):
        """Canonical copyable command: ``cd -- '<cwd>' && [K=V ]argv`` (contracts/agent-tree-v1).

        The folder is always single-quoted; an argv token is quoted only when it holds a
        character outside ``[A-Za-z0-9@%_+=:,./-]``; ``K=V`` pairs are validated, unquoted.
        """
        def quote(value, always=False):
            if not always and value and re.fullmatch(r"[A-Za-z0-9@%_+=:,./-]+", value):
                return value
            return "'" + value.replace("'", "'\\''") + "'"
        parts = []
        for name, value in (environment or {}).items():
            if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", name) or not re.fullmatch(r"[A-Za-z0-9_.:/-]*", value):
                raise ValueError("invalid_agent_environment")
            parts.append(name + "=" + value)
        command = " ".join(parts + [quote(token) for token in argv])
        return ("cd -- " + quote(cwd, always=True) + " && " + command) if cwd else command

    def window_argv(self, window):
        """Launch argv for a saved window; always in no-prompt mode, with or without sessionId."""
        provider = self.provider(window["agent"])
        options = provider.get("windowOptions", [])
        if window.get("model") and not any(option["field"] == "model" for option in options):
            raise ValueError("unsupported_agent_model")
        arguments = [part for option in options if window.get(option["field"])
                     for part in (option["option"], window[option["field"]])]
        if window.get("sessionId"):
            return self.apply_no_prompt(window["agent"], self.resume_argv(window["agent"], window["sessionId"], arguments))
        return self.apply_no_prompt(window["agent"], [provider["executable"], *arguments])
