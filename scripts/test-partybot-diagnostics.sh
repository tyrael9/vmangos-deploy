#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 tyrael9 <https://github.com/tyrael9>
# SPDX-License-Identifier: AGPL-3.0-or-later
set -Eeuo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_DIR="$TMP_DIR/project"
mkdir -p "$PROJECT_DIR/scripts" "$PROJECT_DIR/config" "$TMP_DIR/bin"
cp "$SOURCE_DIR/partybot-diagnostics.sh" "$PROJECT_DIR/scripts/"
cp "$SOURCE_DIR/partybot-trace-report.py" "$PROJECT_DIR/scripts/"
cat >"$PROJECT_DIR/config/mangosd.conf" <<'CONFIG'
PlayerBot.EngineShadow = 1
PlayerBot.DecisionTrace = 1
CONFIG

cat >"$PROJECT_DIR/scripts/partybot-deploy.sh" <<'DEPLOY'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  status) printf 'NAME IMAGE\n' ;;
  logs)
    [[ -n "${PARTYBOT_TEST_LOG:-}" && -f "$PARTYBOT_TEST_LOG" ]]
    cat "$PARTYBOT_TEST_LOG"
    ;;
  *) exit 2 ;;
esac
DEPLOY
chmod 700 "$PROJECT_DIR/scripts/partybot-deploy.sh"

cat >"$TMP_DIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PARTYBOT_TEST_DOCKER_CALLS:?}"
exit 99
DOCKER
chmod 700 "$TMP_DIR/bin/docker"

cat >"$TMP_DIR/trace.log" <<'LOG'
2026-11-19T20:00:00Z [PartyBotShadow] bot=101 group=7 map=33 instance=4 epoch=1 members=5 hostiles=2 candidates=1 selected=1
2026-11-19T20:00:00Z [PartyBotEngineTrace] trace_version=1 encounter_id=123 seq=1 event=encounter_start group=7 map=33 instance=4 bot=101 elapsed_ms=0 reason=combat_detected
2026-11-19T20:00:01Z [PartyBotEngineTrace] trace_version=1 encounter_id=123 seq=2 event=party_snapshot group=7 map=33 instance=4 bot=101 elapsed_ms=1000 snapshot_epoch=2 member_count=5 hostile_count=2 facts=members=101,form=1,cast=2050:1:1:202
2026-11-19T20:00:02Z [PartyBotEngineTrace] trace_version=1 encounter_id=123 seq=3 event=encounter_end group=7 map=33 instance=4 bot=101 elapsed_ms=2000 reason=combat_settled
2026-11-19T20:01:00Z [PartyBotEngineTrace] trace_version=1 encounter_id=456 seq=1 event=encounter_start group=8 map=33 instance=4 bot=102 elapsed_ms=0 reason=combat_detected
2026-11-19T20:01:01Z [PartyBotEngineTrace] trace_version=1 encounter_id=456 seq=2 event=encounter_end group=8 map=33 instance=4 bot=102 elapsed_ms=1000 reason=combat_settled
LOG

export PATH="$TMP_DIR/bin:$PATH"
export PARTYBOT_TEST_LOG="$TMP_DIR/trace.log"
export PARTYBOT_TEST_DOCKER_CALLS="$TMP_DIR/docker.calls"
export PARTYBOT_DIAGNOSTICS_STALE_SECONDS=999999

run_diagnostics() {
  (cd "$PROJECT_DIR" && bash scripts/partybot-diagnostics.sh "$@")
}

assert_file() {
  [[ -f "$1" ]] || { echo "Missing expected file: $1" >&2; exit 1; }
}

assert_mode() {
  local expected="$1" path="$2" actual
  actual="$(stat -c '%a' "$path")"
  [[ "$actual" == "$expected" ]] || {
    echo "Expected mode $expected on $path, got $actual" >&2
    exit 1
  }
}

bash -n "$PROJECT_DIR/scripts/partybot-diagnostics.sh"
python3 -m py_compile "$PROJECT_DIR/scripts/partybot-trace-report.py"

# Default selector must discover every encounter in the captured log tail.
run_diagnostics >/dev/null
REPORT_DIR="$PROJECT_DIR/.partybot/diagnostics/encounters"
assert_file "$REPORT_DIR/encounter-123.md"
assert_file "$REPORT_DIR/encounter-123.raw.log"
assert_file "$REPORT_DIR/encounter-456.md"
assert_file "$REPORT_DIR/encounter-456.raw.log"
assert_mode 700 "$PROJECT_DIR/.partybot"
assert_mode 700 "$PROJECT_DIR/.partybot/diagnostics"
assert_mode 700 "$REPORT_DIR"
assert_mode 600 "$PROJECT_DIR/.partybot/diagnostics/latest.json"
assert_mode 600 "$REPORT_DIR/encounter-123.md"
assert_mode 600 "$REPORT_DIR/encounter-123.raw.log"
grep -Fq 'form=1,cast=2050:1:1:202' "$REPORT_DIR/encounter-123.raw.log"

# Exact ID selector must produce only the requested encounter.
rm -f "$REPORT_DIR"/*
run_diagnostics --encounter-id 123 >/dev/null
assert_file "$REPORT_DIR/encounter-123.md"
[[ ! -e "$REPORT_DIR/encounter-456.md" ]]

# Time-window selector discovers encounter 123 and includes its full timeline.
rm -f "$REPORT_DIR"/*
run_diagnostics --since 2026-11-19T20:00:00Z --until 2026-11-19T20:00:10Z >/dev/null
assert_file "$REPORT_DIR/encounter-123.md"
[[ ! -e "$REPORT_DIR/encounter-456.md" ]]
grep -Fq 'event=encounter_end' "$REPORT_DIR/encounter-123.raw.log"

# Invalid/ambiguous selectors must fail before touching deployment helpers.
if run_diagnostics --encounter-id 0 >/dev/null 2>&1; then
  echo "Zero encounter ID unexpectedly accepted" >&2
  exit 1
fi
if run_diagnostics --since 2026-11-19T20:00:00Z >/dev/null 2>&1; then
  echo "Incomplete time-window selector unexpectedly accepted" >&2
  exit 1
fi
if run_diagnostics --all --encounter-id 123 >/dev/null 2>&1; then
  echo "Conflicting selectors unexpectedly accepted" >&2
  exit 1
fi

[[ ! -s "$PARTYBOT_TEST_DOCKER_CALLS" ]] || {
  echo "Diagnostics unexpectedly invoked Docker: $(cat "$PARTYBOT_TEST_DOCKER_CALLS")" >&2
  exit 1
}

echo "PASS: read-only diagnostics wrapper selectors, report contents, and file permissions"
