#!/usr/bin/env bash
set -euo pipefail
uniconnect_source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--dependencies" ]]; then
    uniconnect_elevate=()
    if [[ "${EUID}" != 0 ]]; then
        uniconnect_elevate=(sudo)
    fi
    "${uniconnect_elevate[@]}" apt-get install -y python3-gi python3-cryptography python3-venv gir1.2-gtk-3.0 gir1.2-vte-2.91 gir1.2-secret-1 openssh-client tmux
fi
# GI/VTE remain distribution packages. Only the Unicode adapter is installed in
# this checkout's private environment; never use pip against system Python.
/usr/bin/python3 -m venv --system-site-packages "${uniconnect_source_dir}/.venv"
"${uniconnect_source_dir}/.venv/bin/python" -m pip install --disable-pip-version-check -r "${uniconnect_source_dir}/requirements-mobile.txt"
/usr/bin/python3 "${uniconnect_source_dir}/install.py"
