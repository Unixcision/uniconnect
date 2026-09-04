#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/install.sh --app <signed-app> [--apply] [--allow-one-time-adhoc-migration] [--launch]

Without --apply this performs every read-only signature and identity check, then stops.
The migration flag is accepted only for the first explicit move from an ad-hoc install.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANDIDATE_APP=""
APPLY="false"
ALLOW_ADHOC_MIGRATION="false"
LAUNCH="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      CANDIDATE_APP="$2"
      shift 2
      ;;
    --apply)
      APPLY="true"
      shift
      ;;
    --allow-one-time-adhoc-migration)
      ALLOW_ADHOC_MIGRATION="true"
      shift
      ;;
    --launch)
      LAUNCH="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -n "$CANDIDATE_APP" && -d "$CANDIDATE_APP" ]] || { usage; exit 2; }
CANDIDATE_PARENT="$(cd "$(dirname "$CANDIDATE_APP")" && pwd -P)"
CANDIDATE_APP="$CANDIDATE_PARENT/$(basename "$CANDIDATE_APP")"
TARGET_APP="/Applications/UniConnect.app"
[[ "$CANDIDATE_APP" != "$TARGET_APP" ]] || { echo "error: candidate must not be the installed app" >&2; exit 1; }

VERIFY_ARGS=("$CANDIDATE_APP" --installed "$TARGET_APP")
if [[ "$ALLOW_ADHOC_MIGRATION" == "true" ]]; then
  VERIFY_ARGS+=(--allow-one-time-adhoc-migration)
fi
"$SCRIPT_DIR/verify-uniconnect-signature.sh" "${VERIFY_ARGS[@]}"

if [[ "$APPLY" != "true" ]]; then
  echo "DRY_RUN_OK: no app, process, permission, session, or history was changed"
  exit 0
fi

[[ -w /Applications ]] || { echo "error: /Applications is not writable by the current user" >&2; exit 1; }

STAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
BACKUP_ROOT="$HOME/.uniconnect/backups/install/$STAMP"
STAGED_APP="/Applications/.UniConnect.install-$$.app"
PREVIOUS_APP="/Applications/.UniConnect.previous-$$.app"
PREVIOUS_MOVED="false"
INSTALL_COMPLETE="false"

cleanup() {
  if [[ -d "$STAGED_APP" ]]; then
    /bin/rm -rf -- "$STAGED_APP"
  fi
  if [[ "$PREVIOUS_MOVED" == "true" && "$INSTALL_COMPLETE" != "true" && -d "$PREVIOUS_APP" && ! -e "$TARGET_APP" ]]; then
    /bin/mv -- "$PREVIOUS_APP" "$TARGET_APP"
  fi
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "$BACKUP_ROOT"
/bin/chmod 700 "$HOME/.uniconnect" "$HOME/.uniconnect/backups" "$HOME/.uniconnect/backups/install" "$BACKUP_ROOT" 2>/dev/null || true

if [[ -d "$TARGET_APP" ]]; then
  /usr/bin/ditto "$TARGET_APP" "$BACKUP_ROOT/UniConnect.app"
  # The one-time migration source may legitimately be the historic ad-hoc (or
  # partially invalid) bundle that this guarded install is replacing. Requiring
  # that old bundle to pass strict code-sign verification here would make the
  # explicitly approved migration impossible. Verify the recoverable copy byte
  # for byte instead; the candidate's stable signature was already checked above.
  /usr/bin/diff -rq "$TARGET_APP" "$BACKUP_ROOT/UniConnect.app" >/dev/null \
    || { echo "error: backup verification failed before installation" >&2; exit 1; }
fi

/usr/bin/ditto "$CANDIDATE_APP" "$STAGED_APP"
STAGED_VERIFY_ARGS=("$STAGED_APP" --installed "$TARGET_APP")
if [[ "$ALLOW_ADHOC_MIGRATION" == "true" ]]; then
  STAGED_VERIFY_ARGS+=(--allow-one-time-adhoc-migration)
fi
"$SCRIPT_DIR/verify-uniconnect-signature.sh" "${STAGED_VERIFY_ARGS[@]}"

if [[ -d "$TARGET_APP" ]]; then
  /usr/bin/osascript -e 'tell application id "com.unixcision.uniconnect" to quit' >/dev/null 2>&1 || true
  for _ in {1..40}; do
    if ! /usr/bin/pgrep -f '^/Applications/UniConnect\.app/Contents/MacOS/UniConnect($| )' >/dev/null 2>&1; then
      break
    fi
    /bin/sleep 0.25
  done
  if /usr/bin/pgrep -f '^/Applications/UniConnect\.app/Contents/MacOS/UniConnect($| )' >/dev/null 2>&1; then
    echo "error: UniConnect is still running; installation was not started" >&2
    exit 1
  fi
  /bin/mv -- "$TARGET_APP" "$PREVIOUS_APP"
  PREVIOUS_MOVED="true"
fi

if ! /bin/mv -- "$STAGED_APP" "$TARGET_APP"; then
  echo "error: failed to move the signed candidate into place" >&2
  exit 1
fi

if ! "$SCRIPT_DIR/verify-uniconnect-signature.sh" "$TARGET_APP"; then
  /bin/mv -- "$TARGET_APP" "$STAGED_APP"
  exit 1
fi

INSTALL_COMPLETE="true"
if [[ -d "$PREVIOUS_APP" ]]; then
  /bin/rm -rf -- "$PREVIOUS_APP"
fi

echo "INSTALL_OK backup=$BACKUP_ROOT app=$TARGET_APP"
if [[ "$LAUNCH" == "true" ]]; then
  /usr/bin/open "$TARGET_APP"
else
  echo "The installed app was not launched."
fi
