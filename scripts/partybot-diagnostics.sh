#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 tyrael9 <https://github.com/tyrael9>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Read-only PartyBot Shadow diagnostics. Does not restart containers or touch DB.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DEPLOY_HELPER="$SCRIPT_DIR/partybot-deploy.sh"
CONFIG_FILE="$PROJECT_DIR/config/mangosd.conf"
TAIL_LINES="${PARTYBOT_DIAGNOSTICS_TAIL:-5000}"
STALE_SECONDS="${PARTYBOT_DIAGNOSTICS_STALE_SECONDS:-120}"
STATE_DIR="$PROJECT_DIR/.partybot/diagnostics"

log() { printf '[partybot-diagnostics] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ -x "$DEPLOY_HELPER" ]] || die "Missing executable $DEPLOY_HELPER"
[[ -f "$CONFIG_FILE" ]] || die "Missing $CONFIG_FILE"
command -v docker >/dev/null 2>&1 || die "Docker is required"
command -v python3 >/dev/null 2>&1 || die "Python 3 is required"
[[ "$TAIL_LINES" =~ ^[0-9]+$ ]] || die "PARTYBOT_DIAGNOSTICS_TAIL must be an integer"
[[ "$STALE_SECONDS" =~ ^[0-9]+$ ]] || die "PARTYBOT_DIAGNOSTICS_STALE_SECONDS must be an integer"

mkdir -p "$STATE_DIR"
chmod 700 "$PROJECT_DIR/.partybot" "$STATE_DIR"
tmp_logs="$(mktemp)"
tmp_status="$(mktemp)"
trap 'rm -f "$tmp_logs" "$tmp_status"' EXIT

log "Reading effective server status (read-only)..."
"$DEPLOY_HELPER" status >"$tmp_status" || die "Could not read deployment status"
log "Reading the last $TAIL_LINES mangosd/realmd log lines..."
"$DEPLOY_HELPER" logs "$TAIL_LINES" >"$tmp_logs" || die "Could not read container logs"

python3 - "$CONFIG_FILE" "$tmp_logs" "$tmp_status" "$STATE_DIR" "$STALE_SECONDS" <<'PY'
import datetime as dt
import json
import pathlib
import re
import sys

config_path, logs_path, status_path, output_dir, stale_seconds = sys.argv[1:]
stale_seconds = int(stale_seconds)
now = dt.datetime.now(dt.timezone.utc)

def read_config_value(key, default="0"):
    pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=\s*([^#\s]+)", re.I)
    found = None
    for line in pathlib.Path(config_path).read_text(errors="replace").splitlines():
        match = pattern.match(line)
        if match:
            found = match.group(1).strip().strip('"').strip("'")
    return found if found is not None else default

def parse_timestamp(line):
    match = re.search(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d))", line)
    if not match:
        return None
    value = match.group(1).replace("Z", "+00:00")
    try:
        return dt.datetime.fromisoformat(value).astimezone(dt.timezone.utc)
    except ValueError:
        return None

status_re = re.compile(r"\\[PartyBotShadowStatus\\]\\s+bot=(\\d+)\\s+group=(\\d+)\\s+map=(\\d+)\\s+instance=(\\d+)\\s+status=([A-Za-z0-9_]+)")
shadow_statuses = []
for line in pathlib.Path(logs_path).read_text(errors="replace").splitlines():
    match = status_re.search(line)
    if match:
        stamp = parse_timestamp(line)
        shadow_statuses.append({
            "bot": int(match.group(1)), "group": int(match.group(2)),
            "map": int(match.group(3)), "instance": int(match.group(4)),
            "status": match.group(5),
            "timestamp": stamp.isoformat() if stamp else None,
            "_time": stamp,
        })

shadow_re = re.compile(
    r"\[PartyBotShadow\]\s+bot=(\d+)\s+group=(\d+)\s+map=(\d+)\s+"
    r"instance=(\d+)\s+epoch=(\d+)\s+members=(\d+)\s+hostiles=(\d+)\s+"
    r"candidates=(\d+)\s+selected=(\d+)"
)
records = []
unparsed_shadow = 0
for line in pathlib.Path(logs_path).read_text(errors="replace").splitlines():
    if "[PartyBotShadow]" not in line:
        continue
    match = shadow_re.search(line)
    if not match:
        unparsed_shadow += 1
        continue
    values = [int(x) for x in match.groups()]
    stamp = parse_timestamp(line)
    records.append({
        "bot": values[0], "group": values[1], "map": values[2],
        "instance": values[3], "epoch": values[4], "members": values[5],
        "hostiles": values[6], "candidates": values[7], "selected": values[8],
        "timestamp": stamp.isoformat() if stamp else None,
        "_time": stamp,
    })

engine_shadow = read_config_value("PlayerBot.EngineShadow", "0")
decision_trace = read_config_value("PlayerBot.DecisionTrace", "0")
checks = []
def check(level, name, detail):
    checks.append({"status": level, "name": name, "detail": detail})

if engine_shadow not in ("1", "true", "TRUE", "yes", "on"):
    check("WARN", "shadow_config", f"PlayerBot.EngineShadow={engine_shadow}; Shadow is disabled")
else:
    check("PASS", "shadow_config", "PlayerBot.EngineShadow is enabled")

if decision_trace not in ("1", "true", "TRUE", "yes", "on"):
    check("WARN", "decision_trace_config", f"PlayerBot.DecisionTrace={decision_trace}; summaries are not expected")
else:
    check("PASS", "decision_trace_config", "PlayerBot.DecisionTrace is enabled")

if not records:
    if shadow_statuses and all(s["status"] == "no_supported_group" for s in shadow_statuses):
        check("INFO", "shadow_heartbeat", "Shadow is enabled, but sampled bots currently have no supported normal party")
    else:
        check("WARN", "shadow_heartbeat", "No parseable [PartyBotShadow] evaluation summaries in the selected log window")
else:
    latest = max((r["_time"] for r in records if r["_time"]), default=None)
    if latest is None:
        check("WARN", "shadow_freshness", "Shadow lines found, but Docker timestamps were unavailable")
    else:
        age = max(0, int((now - latest).total_seconds()))
        if age > stale_seconds:
            check("WARN", "shadow_freshness", f"Last summary is {age}s old (threshold {stale_seconds}s)")
        else:
            check("PASS", "shadow_freshness", f"Last summary is {age}s old")

    bots = sorted({r["bot"] for r in records})
    groups = sorted({(r["group"], r["map"], r["instance"]) for r in records})
    bad = [r for r in records if r["members"] < 1 or r["group"] == 0]
    if bad:
        check("FAIL", "snapshot_identity", f"{len(bad)} summaries have group=0 or members<1")
    else:
        check("PASS", "snapshot_identity", "All summaries have a nonzero group and at least one same-map member")

    if len(groups) > 1:
        check("INFO", "observed_shards", f"Observed {len(groups)} (group,map,instance) keys; this can be normal during travel")
    else:
        check("PASS", "observed_shards", f"Observed group/map/instance {groups[0]}")

    if all(r["candidates"] == 0 and r["selected"] == 0 for r in records):
        check("INFO", "engine_candidates", "candidates=0 and selected=0 are expected until runtime strategies/actions are registered")
    else:
        check("INFO", "engine_candidates", "Nonzero candidate/selection counts observed; inspect strategy diagnostics before enabling execution")

status_counts = {}
for item in shadow_statuses:
    status_counts[item["status"]] = status_counts.get(item["status"], 0) + 1
for status, count in sorted(status_counts.items()):
    if status in ("snapshot_unavailable", "bot_missing_from_snapshot", "coordinator_unavailable"):
        check("WARN", "shadow_runtime_status", f"{status}: {count} sampled status records")
    elif status == "no_supported_group":
        check("INFO", "shadow_runtime_status", f"no_supported_group: {count} sampled status records")
if unparsed_shadow:
    check("WARN", "log_format", f"{unparsed_shadow} Shadow lines did not match the expected key/value format")

status_text = pathlib.Path(status_path).read_text(errors="replace")
image_lines = [line.strip() for line in status_text.splitlines() if "ghcr.io/" in line]
report = {
    "generated_at": now.isoformat(),
    "config": {
        "PlayerBot.EngineShadow": engine_shadow,
        "PlayerBot.DecisionTrace": decision_trace,
    },
    "log_window": {
        "shadow_summaries": len(records),
        "bots": sorted({r["bot"] for r in records}),
        "shards": [{"group": g, "map": m, "instance": i} for g, m, i in sorted({(r["group"], r["map"], r["instance"]) for r in records})],
        "last_summary_at": max((r["_time"] for r in records if r["_time"]), default=None).isoformat()
            if any(r["_time"] for r in records) else None,
        "candidates_total": sum(r["candidates"] for r in records),
        "selected_total": sum(r["selected"] for r in records),
        "hostiles_max": max((r["hostiles"] for r in records), default=0),
        "members_max": max((r["members"] for r in records), default=0),
    },
    "image_references": image_lines,
    "checks": checks,
    "limitations": [
        "This is a read-only log/config/container diagnostic, not proof of correct in-game decisions.",
        "A missing heartbeat can mean Shadow is disabled, no eligible party bot is active, the log window is too short, or snapshot construction did not complete.",
        "The current engine has no registered runtime strategies/actions; zero candidates is expected.",
        "Legacy remains the only action executor in Shadow mode.",
    ],
}
for record in records:
    record.pop("_time", None)
report["recent_shadow_summaries"] = records[-20:]

out = pathlib.Path(output_dir) / "latest.json"
out.write_text(json.dumps(report, indent=2) + "\n")
out.chmod(0o600)

print("\nPartyBot diagnostics")
print("====================")
print(f"Generated: {report['generated_at']}")
print(f"Shadow config: {engine_shadow} | DecisionTrace: {decision_trace}")
print(f"Parsed summaries: {len(records)} | Status records: {len(shadow_statuses)} | Bots: {len(report['log_window']['bots'])}")
print(f"Observed shards: {len(report['log_window']['shards'])}")
print(f"Max members: {report['log_window']['members_max']} | Max hostiles: {report['log_window']['hostiles_max']}")
print(f"Candidates total: {report['log_window']['candidates_total']} | Selected total: {report['log_window']['selected_total']}")
if image_lines:
    print("Images:")
    for line in image_lines:
        print("  " + line)
print("\nChecks:")
for item in checks:
    print(f"  [{item['status']}] {item['name']}: {item['detail']}")
print(f"\nJSON report: {out}")
fails = sum(c["status"] == "FAIL" for c in checks)
warns = sum(c["status"] == "WARN" for c in checks)
print(f"\nResult: {'FAIL' if fails else ('WARN' if warns else 'PASS')} ({fails} fail, {warns} warn)")
PY
