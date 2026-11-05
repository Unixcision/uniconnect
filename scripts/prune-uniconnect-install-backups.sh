#!/usr/bin/env bash
# Keeps only the newest install backups of UniConnect.app.
#
# scripts/install.sh copies the replaced app (about 330 MB) to
# ~/.uniconnect/backups/install/<UTC stamp>/ so an install can be rolled back.
# This keeps the newest <keep> copies (2 by default: the version just replaced
# and the one before it) and deletes the older ones. Only folders named like a
# stamp (20260925T210702Z) count; anything else in the folder is left alone.
set -euo pipefail

usage() { echo "usage: scripts/prune-uniconnect-install-backups.sh <install-backups-dir> [keep]" >&2; }

ROOT="${1:-}"
KEEP="${2:-2}"
[[ -n "$ROOT" ]] || { usage; exit 2; }
[[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 ]] || { echo "error: keep must be at least 1, or there is nothing to roll back to" >&2; exit 2; }
[[ -d "$ROOT" ]] || { echo "INSTALL_BACKUPS kept=0 removed=0"; exit 0; }

seen=0
removed=0
while IFS= read -r stamp; do
  seen=$((seen + 1))
  if (( seen > KEEP )); then
    /bin/rm -rf -- "${ROOT:?}/$stamp"
    removed=$((removed + 1))
  fi
done < <(/bin/ls -1 "$ROOT" | /usr/bin/grep -E '^[0-9]{8}T[0-9]{6}Z$' | /usr/bin/sort -r || true)

echo "INSTALL_BACKUPS kept=$((seen - removed)) removed=$removed"
