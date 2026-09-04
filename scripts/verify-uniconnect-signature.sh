#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <candidate-app> [--installed <installed-app>] [--allow-one-time-adhoc-migration]" >&2
}

designated_requirement() {
  /usr/bin/codesign -d -r- "$1" 2>&1 \
    | /usr/bin/sed -n 's/^# designated => //p; s/^designated => //p' \
    | /usr/bin/head -n 1
}

signature_field() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 \
    | /usr/bin/sed -n "s/^$2=//p" \
    | /usr/bin/head -n 1
}

reject() {
  echo "$1" >&2
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

CANDIDATE_APP="$1"
shift
INSTALLED_APP=""
ALLOW_ADHOC_MIGRATION="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --installed)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      INSTALLED_APP="$2"
      shift 2
      ;;
    --allow-one-time-adhoc-migration)
      ALLOW_ADHOC_MIGRATION="true"
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -d "$CANDIDATE_APP" ]] || reject "REJECT_CANDIDATE_MISSING: $CANDIDATE_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$CANDIDATE_APP" >/dev/null 2>&1 \
  || reject "REJECT_CANDIDATE_INVALID"

CANDIDATE_IDENTIFIER="$(signature_field "$CANDIDATE_APP" Identifier)"
CANDIDATE_SIGNATURE="$(signature_field "$CANDIDATE_APP" Signature)"
CANDIDATE_TEAM="$(signature_field "$CANDIDATE_APP" TeamIdentifier)"
CANDIDATE_REQUIREMENT="$(designated_requirement "$CANDIDATE_APP")"

[[ "$CANDIDATE_IDENTIFIER" == "com.unixcision.uniconnect" ]] \
  || reject "REJECT_CANDIDATE_IDENTIFIER"
[[ -n "$CANDIDATE_REQUIREMENT" ]] || reject "REJECT_CANDIDATE_REQUIREMENT_MISSING"
[[ "$CANDIDATE_SIGNATURE" != "adhoc" ]] || reject "REJECT_CANDIDATE_ADHOC"
[[ -n "$CANDIDATE_TEAM" && "$CANDIDATE_TEAM" != "not set" ]] \
  || reject "REJECT_CANDIDATE_TEAM_MISSING"
[[ "$CANDIDATE_REQUIREMENT" != cdhash\ * ]] \
  || reject "REJECT_CANDIDATE_UNSTABLE_REQUIREMENT"

if [[ -n "$INSTALLED_APP" && -e "$INSTALLED_APP" ]]; then
  [[ -d "$INSTALLED_APP" ]] || reject "REJECT_INSTALLED_NOT_APP"
  INSTALLED_IDENTIFIER="$(signature_field "$INSTALLED_APP" Identifier)"
  INSTALLED_SIGNATURE="$(signature_field "$INSTALLED_APP" Signature)"
  INSTALLED_TEAM="$(signature_field "$INSTALLED_APP" TeamIdentifier)"
  INSTALLED_REQUIREMENT="$(designated_requirement "$INSTALLED_APP")"

  [[ "$INSTALLED_IDENTIFIER" == "$CANDIDATE_IDENTIFIER" ]] \
    || reject "REJECT_IDENTIFIER_CHANGE"

  if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP" >/dev/null 2>&1; then
    [[ "$ALLOW_ADHOC_MIGRATION" == "true" ]] \
      || reject "REJECT_INSTALLED_INVALID: explicit one-time migration approval is required"
    echo "ALLOW_ONE_TIME_INVALID_SIGNATURE_MIGRATION"
  elif [[ "$INSTALLED_SIGNATURE" == "adhoc" || -z "$INSTALLED_TEAM" || "$INSTALLED_TEAM" == "not set" || "$INSTALLED_REQUIREMENT" == cdhash\ * ]]; then
    [[ "$ALLOW_ADHOC_MIGRATION" == "true" ]] \
      || reject "REJECT_INSTALLED_ADHOC: rerun only after explicit approval with --allow-one-time-adhoc-migration"
    echo "ALLOW_ONE_TIME_ADHOC_MIGRATION"
  else
    [[ "$INSTALLED_TEAM" == "$CANDIDATE_TEAM" ]] || reject "REJECT_TEAM_CHANGE"
    /usr/bin/codesign --verify --deep --strict --verbose=2 \
      -R="$INSTALLED_REQUIREMENT" "$CANDIDATE_APP" >/dev/null 2>&1 \
      || reject "REJECT_DESIGNATED_REQUIREMENT_CHANGE"
  fi
fi

echo "SIGNATURE_OK team=$CANDIDATE_TEAM identifier=$CANDIDATE_IDENTIFIER"
