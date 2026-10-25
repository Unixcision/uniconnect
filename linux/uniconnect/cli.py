"""Command-line client for the private UniConnect desktop socket."""

import argparse
import json
import os
from pathlib import Path
import socket


def main():
    parser = argparse.ArgumentParser(prog="cmux", description=__doc__)
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH") or str(Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "uniconnect/control.sock"))
    parser.add_argument("--workspace")
    parser.add_argument("--surface")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("command", nargs="?", default="ping")
    parser.add_argument("text", nargs="*", default=[])
    options = parser.parse_args()
    if options.command == "antigravity-integration":
        from uniconnect.antigravity_integration import AntigravityIntegration, IntegrationError
        if len(options.text) != 1 or options.text[0] not in ("enable", "disable", "status"):
            parser.exit(2, "Usage: uniconnect-cli antigravity-integration enable|disable|status\n")
        integration = AntigravityIntegration()
        try:
            result = {"enable": integration.enable, "disable": integration.disable,
                      "status": integration.status}[options.text[0]]()
        except IntegrationError as error:
            parser.exit(1, "Antigravity integration unchanged: " + str(error) + "\n")
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    request = {"command": options.command, "workspace": options.workspace, "surface": options.surface, "text": " ".join(options.text)}
    try:
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(12)
            client.connect(options.socket)
            client.sendall(json.dumps(request).encode() + b"\n")
            response = bytearray()
            while b"\n" not in response:
                chunk = client.recv(65536)
                if not chunk:
                    raise ValueError("Connection closed before a response")
                response.extend(chunk)
                if len(response) > 2 * 1024 * 1024:
                    raise ValueError("Response is too large")
        result = json.loads(response)
        if not result["ok"]:
            raise ValueError(result["error"])
        value = result["result"]
        print(json.dumps(value, ensure_ascii=False, indent=2) if options.json or not isinstance(value, str) else value)
        return 0
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
