#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build read-only, encounter-scoped reports from PartyBotEngine log lines.

The collector reads local log files only. It never connects to a server or
database, and it never changes the source logs.
"""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import re
import sys
from typing import Iterable, Optional

TRACE_PREFIX = "[PartyBotEngineTrace]"
TIMESTAMP_RE = re.compile(
    r"^(?P<timestamp>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}"
    r"(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?)"
)
FIELD_RE = re.compile(r"(?P<key>[A-Za-z_][A-Za-z0-9_]*)=(?P<value>[^\s]+)")


@dataclass(frozen=True)
class TraceRecord:
    encounter_id: int
    sequence: int
    event: str
    fields: dict[str, str]
    raw_line: str
    source: str
    line_number: int
    timestamp: Optional[datetime]


def parse_timestamp(line: str) -> Optional[datetime]:
    match = TIMESTAMP_RE.match(line)
    if not match:
        return None
    value = match.group("timestamp").replace(",", ".")
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def parse_trace_line(line: str, source: str = "<memory>",
                     line_number: int = 1) -> Optional[TraceRecord]:
    marker = line.find(TRACE_PREFIX)
    if marker < 0:
        return None
    payload = line[marker + len(TRACE_PREFIX):]
    fields = {match.group("key"): match.group("value")
              for match in FIELD_RE.finditer(payload)}
    try:
        encounter_id = int(fields["encounter_id"], 10)
        sequence = int(fields["seq"], 10)
        event = fields["event"]
    except (KeyError, ValueError):
        return None
    if encounter_id <= 0 or sequence <= 0:
        return None
    return TraceRecord(
        encounter_id=encounter_id,
        sequence=sequence,
        event=event,
        fields=fields,
        raw_line=line.rstrip("\r\n"),
        source=source,
        line_number=line_number,
        timestamp=parse_timestamp(line),
    )


def parse_datetime_argument(value: str) -> datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        return datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"invalid ISO-8601 datetime: {value}"
        ) from exc


def iter_input_files(inputs: Iterable[Path], output_dir: Path) -> list[Path]:
    files: list[Path] = []
    seen: set[Path] = set()
    excluded = output_dir.resolve()
    for item in inputs:
        path = item.expanduser()
        if not path.exists():
            raise FileNotFoundError(f"input path does not exist: {path}")
        candidates = [path] if path.is_file() else sorted(
            child for child in path.rglob("*") if child.is_file()
        )
        for candidate in candidates:
            resolved = candidate.resolve()
            if resolved == excluded or excluded in resolved.parents:
                continue
            if resolved not in seen:
                seen.add(resolved)
                files.append(candidate)
    return files


def load_trace_records(files: Iterable[Path]) -> tuple[list[TraceRecord], int, int]:
    records: list[TraceRecord] = []
    scanned_lines = 0
    malformed_trace_lines = 0
    for path in files:
        try:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                for number, line in enumerate(handle, 1):
                    scanned_lines += 1
                    if TRACE_PREFIX not in line:
                        continue
                    record = parse_trace_line(line, str(path), number)
                    if record is None:
                        malformed_trace_lines += 1
                    else:
                        records.append(record)
        except OSError as exc:
            raise OSError(f"cannot read input log {path}: {exc}") from exc
    return records, scanned_lines, malformed_trace_lines


def select_encounters(records: Iterable[TraceRecord],
                      encounter_id: Optional[int],
                      since: Optional[datetime],
                      until: Optional[datetime],
                      all_encounters: bool = False) -> tuple[dict[int, list[TraceRecord]], int]:
    all_records = list(records)
    if all_encounters:
        selected: dict[int, list[TraceRecord]] = {}
        for record in all_records:
            selected.setdefault(record.encounter_id, []).append(record)
        return selected, 0

    if encounter_id is not None:
        selected = [record for record in all_records
                    if record.encounter_id == encounter_id]
        return ({encounter_id: selected} if selected else {}), 0

    if since is None and until is None:
        return {}, 0

    matching_ids: set[int] = set()
    missing_timestamp = 0
    for record in all_records:
        if record.timestamp is None:
            missing_timestamp += 1
            continue
        try:
            in_window = (since is None or record.timestamp >= since) and (
                until is None or record.timestamp <= until
            )
        except TypeError as exc:
            raise ValueError(
                "time-window arguments must use the same timezone style "
                "as timestamps in the input logs"
            ) from exc
        if in_window:
            matching_ids.add(record.encounter_id)

    # The window discovers encounters. Include all available lines for each
    # matching ID so the report is a full timeline, not just a clipped slice.
    selected: dict[int, list[TraceRecord]] = {}
    for record in all_records:
        if record.encounter_id in matching_ids:
            selected.setdefault(record.encounter_id, []).append(record)
    return selected, missing_timestamp

def _format_event_summary(record: TraceRecord) -> str:
    fields = record.fields
    keys = (
        "bot", "source", "action", "action_id", "target", "old_victim",
        "new_victim", "spell", "accepted", "result_code", "outcome",
        "status", "reason", "category", "truncated",
    )
    details = [f"{key}={fields[key]}" for key in keys if key in fields]
    return ", ".join(details) if details else "—"


def build_report(encounter_id: int, records: list[TraceRecord],
                 scanned_lines: int, malformed_trace_lines: int,
                 missing_timestamp_lines: int = 0) -> tuple[str, str]:
    ordered = sorted(records, key=lambda item: item.sequence)
    counts = Counter(record.event for record in ordered)
    sequences = [record.sequence for record in ordered]
    unique_sequences = sorted(set(sequences))
    duplicate_count = len(sequences) - len(unique_sequences)
    gaps: list[tuple[int, int]] = []
    for left, right in zip(unique_sequences, unique_sequences[1:]):
        if right > left + 1:
            gaps.append((left + 1, right - 1))

    warnings: list[str] = []
    if "encounter_start" not in counts:
        warnings.append("No encounter_start record was found in the selected logs.")
    if "encounter_end" not in counts:
        warnings.append("No encounter_end record was found; the log window may be incomplete or the encounter may still be active.")
    if counts.get("trace_limit", 0):
        warnings.append(f"Found {counts['trace_limit']} trace_limit record(s); some diagnostic events were intentionally suppressed.")
    if any(record.fields.get("truncated") == "1" for record in ordered):
        warnings.append("At least one party_snapshot payload was truncated.")
    omitted_fields = ("members_omitted", "companions_omitted", "hostiles_omitted")
    if any(int(record.fields.get(key, "0")) > 0
           for record in ordered for key in omitted_fields
           if record.fields.get(key, "0").isdigit()):
        warnings.append("At least one party_snapshot omitted entities beyond its bounded payload.")
    if gaps:
        warnings.append("Encounter sequence gaps were observed. They can indicate rate limiting or missing log lines; they are not proof of a server failure.")
    if duplicate_count:
        warnings.append(f"Found {duplicate_count} record(s) with a repeated sequence number.")
    if malformed_trace_lines:
        warnings.append(f"Skipped {malformed_trace_lines} malformed PartyBotEngineTrace line(s) while scanning the input.")
    if missing_timestamp_lines:
        warnings.append(f"Skipped {missing_timestamp_lines} trace line(s) without a parseable timestamp during time-window selection.")

    first = unique_sequences[0] if unique_sequences else 0
    last = unique_sequences[-1] if unique_sequences else 0
    lines = [
        f"# PartyBot encounter report — {encounter_id}",
        "",
        f"- Records: **{len(ordered)}**",
        f"- Sequence range: **{first}–{last}**",
        f"- Unique sequence numbers: **{len(unique_sequences)}**",
        f"- Sequence gaps: **{len(gaps)}**",
        f"- Repeated sequence records: **{duplicate_count}**",
        f"- Input lines scanned: **{scanned_lines}**",
        "",
        "## Event counts",
        "",
        "| Event | Count |",
        "|---|---:|",
    ]
    for event, count in sorted(counts.items()):
        lines.append(f"| {event} | {count} |")

    lines.extend(["", "## Timeline", "",
                  "| Seq | Elapsed ms | Event | Details |",
                  "|---:|---:|---|---|"])
    for record in ordered:
        elapsed = record.fields.get("elapsed_ms", "—")
        details = _format_event_summary(record).replace("|", "\\|")
        lines.append(
            f"| {record.sequence} | {elapsed} | {record.event} | {details} |"
        )

    lines.extend(["", "## Sequence gaps", ""])
    if gaps:
        for start, end in gaps:
            lines.append(f"- Missing sequence range: {start}–{end}")
    else:
        lines.append("No gaps detected in the selected sequence numbers.")

    lines.extend(["", "## Warnings", ""])
    if warnings:
        lines.extend(f"- {warning}" for warning in warnings)
    else:
        lines.append("No truncation, trace-limit, missing-boundary or sequence-gap warnings were detected.")

    lines.extend([
        "",
        "## Interpretation notes",
        "",
        "- A candidate or decision_summary is evidence of evaluation, not proof that Core executed the action.",
        "- cast_request_result records synchronous request acceptance; cast_terminal records the later Core spell outcome.",
        "- A missing sequence can result from an explicit per-tick cap or from incomplete log collection.",
        "- This report contains only the structured trace lines selected for this encounter. The paired raw log file preserves those original lines.",
        "",
    ])
    report_text = "\n".join(lines)
    raw_text = "\n".join(record.raw_line for record in ordered) + "\n"
    return report_text, raw_text


def write_encounter_report(output_dir: Path, encounter_id: int,
                            records: list[TraceRecord], scanned_lines: int,
                            malformed_trace_lines: int,
                            missing_timestamp_lines: int = 0) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    rendered, raw = build_report(
        encounter_id, records, scanned_lines, malformed_trace_lines,
        missing_timestamp_lines,
    )
    stem = f"encounter-{encounter_id}"
    report_path = output_dir / f"{stem}.md"
    raw_path = output_dir / f"{stem}.raw.log"
    report_path.write_text(rendered, encoding="utf-8")
    raw_path.write_text(raw, encoding="utf-8")
    # Encounter reports contain player/party GUIDs and raw server diagnostics.
    # Restrict both artifacts to the current account on Unix-like hosts.
    report_path.chmod(0o600)
    raw_path.chmod(0o600)
    return report_path, raw_path


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Create read-only PartyBotEngine encounter reports from local mangosd logs."
    )
    parser.add_argument("logs", nargs="+", type=Path,
                        help="log file(s) or directory/directories to scan")
    selector = parser.add_mutually_exclusive_group(required=True)
    selector.add_argument("--all", action="store_true",
                          help="write reports for every encounter found in the input logs")
    selector.add_argument("--encounter-id",
                          help="exact decimal encounter_id from PartyBotEngineTrace")
    selector.add_argument("--since", type=parse_datetime_argument,
                          help="ISO-8601 start of a timestamp window; use with --until")
    parser.add_argument("--until", type=parse_datetime_argument,
                        help="ISO-8601 end of a timestamp window")
    parser.add_argument("--output-dir", type=Path, default=Path("partybot-reports"),
                        help="where report and raw-log files are written (default: partybot-reports)")
    args = parser.parse_args(argv)

    if (args.since is None) != (args.until is None):
        parser.error("--since and --until must be supplied together")
    if args.since is not None and args.until < args.since:
        parser.error("--until must not be earlier than --since")

    try:
        files = iter_input_files(args.logs, args.output_dir)
        records, scanned_lines, malformed = load_trace_records(files)
        encounter_id = int(args.encounter_id, 10) if args.encounter_id else None
        if encounter_id is not None and encounter_id <= 0:
            parser.error("--encounter-id must be a positive decimal integer")
        selected, missing_timestamps = select_encounters(
            records, encounter_id, args.since, args.until, args.all
        )
        if not selected:
            print("No matching PartyBotEngineTrace records were found.", file=sys.stderr)
            return 2
        for selected_id, encounter_records in sorted(selected.items()):
            report_path, raw_path = write_encounter_report(
                args.output_dir, selected_id, encounter_records,
                scanned_lines, malformed, missing_timestamps,
            )
            print(f"Encounter {selected_id}: {len(encounter_records)} trace records")
            print(f"  report: {report_path}")
            print(f"  raw:    {raw_path}")
        return 0
    except (OSError, ValueError) as exc:
        print(f"partybot trace report: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
