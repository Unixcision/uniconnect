"""Thin decoder for CMUXAgentLaunch's canonical command syntax resource.

This does not sanitize captured provider arguments or choose approval modes.
Those policies remain in Swift; Linux supplies only its validated window fields.
"""

import json
from pathlib import Path


class AgentResumeCatalog:
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

    def provider(self, kind):
        return self.providers[self.aliases.get(kind, kind)]

    def resume_argv(self, kind, session_id, arguments=(), *, executable=None):
        provider = self.provider(kind)
        substitutions = {"{executable}": [executable or provider["executable"]],
                         "{sessionId}": [session_id], "{arguments}": list(arguments)}
        return [arg for token in provider["resume"] for arg in substitutions.get(token, [token])]

    def window_argv(self, window):
        provider = self.provider(window["agent"])
        options = provider.get("windowOptions", [])
        if window.get("model") and not any(option["field"] == "model" for option in options):
            raise ValueError("unsupported_agent_model")
        arguments = [part for option in options if window.get(option["field"])
                     for part in (option["option"], window[option["field"]])]
        if window.get("sessionId"):
            return self.resume_argv(window["agent"], window["sessionId"], arguments)
        return [provider["executable"], *arguments]
