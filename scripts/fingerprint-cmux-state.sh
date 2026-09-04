#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 capture <output-file> | compare <before-file> <after-file>" >&2
}

reject() {
  echo "ERROR: $1" >&2
  exit 2
}

encode_path() {
  /usr/bin/printf '%s' "$1" | /usr/bin/base64 | /usr/bin/tr -d '\n'
}

record_absent() {
  /usr/bin/printf 'ABSENT|%s\n' "$(encode_path "$1")"
}

record_path() {
  local path="$1"
  local kind metadata digest target

  if [[ -L "$path" ]]; then
    kind="LINK"
    metadata="$(/usr/bin/stat -f '%z|%m|%c|%Sp|%i' "$path")"
    target="$(/usr/bin/readlink "$path")"
    /usr/bin/printf '%s|%s|%s|%s\n' \
      "$kind" "$(encode_path "$path")" "$metadata" "$(encode_path "$target")"
    return
  fi

  if [[ -d "$path" ]]; then
    kind="DIR"
    metadata="$(/usr/bin/stat -f '%z|%m|%c|%Sp|%i' "$path")"
    /usr/bin/printf '%s|%s|%s\n' "$kind" "$(encode_path "$path")" "$metadata"
    return
  fi

  if [[ -f "$path" ]]; then
    kind="FILE"
    metadata="$(/usr/bin/stat -f '%z|%m|%c|%Sp|%i' "$path")"
    digest="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')"
    /usr/bin/printf '%s|%s|%s|%s\n' \
      "$kind" "$(encode_path "$path")" "$metadata" "$digest"
    return
  fi

  record_absent "$path"
}

record_tree() {
  local root="$1"
  local path
  if [[ ! -e "$root" && ! -L "$root" ]]; then
    record_absent "$root"
    return
  fi

  while IFS= read -r -d '' path; do
    record_path "$path"
  done < <(/usr/bin/find "$root" -xdev -print0)
}

capture() {
  local output="$1"
  local output_parent temporary preference socket pid started
  local support_root="$HOME/Library/Application Support/cmux"
  local config_root="$HOME/.config/cmux"

  output_parent="$(/usr/bin/dirname "$output")"
  [[ -d "$output_parent" ]] || reject "output directory does not exist"
  temporary="$(/usr/bin/mktemp "$output_parent/.cmux-fingerprint.XXXXXX")"
  /bin/chmod 600 "$temporary"
  trap '/bin/rm -f -- "$temporary"' EXIT INT TERM

  preference="$HOME/Library/Preferences/com.cmuxterm.app.plist"
  {
    record_tree "$support_root"
    record_tree "$config_root"
    record_path "$preference"

    while IFS= read -r -d '' socket; do
      record_path "$socket"
    done < <(/usr/bin/find /tmp -xdev -maxdepth 1 -type s -name 'cmux*.sock' -print0)

    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      started="$(/bin/ps -p "$pid" -o lstart= | /usr/bin/sed 's/^[[:space:]]*//')"
      /usr/bin/printf 'PROCESS|cmux.app|%s|%s\n' "$pid" "$started"
    done < <(/usr/bin/pgrep -f '^/Applications/cmux\.app/Contents/MacOS/cmux($| )' 2>/dev/null || true)
  } | LC_ALL=C /usr/bin/sort > "$temporary"

  /bin/chmod 600 "$temporary"
  /bin/mv -f "$temporary" "$output"
  trap - EXIT INT TERM
  /usr/bin/printf 'CAPTURED: private cmux fingerprint written (%s bytes)\n' \
    "$(/usr/bin/stat -f '%z' "$output")"
}

compare() {
  local before="$1"
  local after="$2"
  [[ -f "$before" ]] || reject "before fingerprint is missing"
  [[ -f "$after" ]] || reject "after fingerprint is missing"

  if /usr/bin/cmp -s "$before" "$after"; then
    echo "PASS: cmux fingerprint unchanged"
    return
  fi
  echo "FAIL: cmux fingerprint changed; inspect the private files locally" >&2
  return 1
}

case "${1:-}" in
  capture)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    capture "$2"
    ;;
  compare)
    [[ $# -eq 3 ]] || { usage; exit 2; }
    compare "$2" "$3"
    ;;
  *)
    usage
    exit 2
    ;;
esac
