#!/usr/bin/env bash
set -euo pipefail
uniconnect_source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--dependencies" ]]; then
    apt-get install -y python3-gi python3-cryptography gir1.2-gtk-3.0 gir1.2-vte-2.91 gir1.2-secret-1 openssh-client tmux
fi
/usr/bin/python3 "${uniconnect_source_dir}/install.py"
