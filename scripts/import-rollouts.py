#!/usr/bin/env python3
"""One-off import of Codex rollout history into the CodexTPS database.

CodexTPS records responses from Codex telemetry only. Responses from before the
telemetry exporter was enabled (or while the app was not running) live only in
Codex's rollout logs; this script reads them and inserts one row per model
response. Rows already captured through telemetry are skipped.

A response is timed from the last event that hands control back to the model
(turn start, tool output, user message) to its `token_usage_record`, so these
rows have end-to-end timing only and no time to first token.

Usage: scripts/import-rollouts.py [--codex-home ~/.codex] [--db PATH] [--dry-run]
"""
import argparse
import glob
import json
import os
import sqlite3
from datetime import datetime

SCHEMA = """
CREATE TABLE IF NOT EXISTS responses (
    thread_id TEXT NOT NULL,
    end_at REAL NOT NULL,
    model TEXT NOT NULL,
    effort TEXT NOT NULL,
    tier TEXT NOT NULL,
    output_tokens INTEGER NOT NULL,
    reasoning_tokens INTEGER NOT NULL,
    duration REAL NOT NULL,
    ttft REAL,
    PRIMARY KEY (thread_id, end_at)
);
CREATE INDEX IF NOT EXISTS responses_end ON responses(end_at);
"""

# Only these lines matter; checking the head avoids JSON-parsing multi-megabyte tool output.
NEEDLES = (b"token_usage_record", b"thread_settings_applied", b"turn_context", b"task_started",
           b"task_complete", b"turn_aborted", b"call_output", b'"role":"user"')


def timestamp(o):
    return datetime.fromisoformat(o["timestamp"].replace("Z", "+00:00")).timestamp()


def responses(path):
    thread_from_name = os.path.basename(path).rsplit(".", 1)[0][-36:]
    model, effort, tier, start = "?", "?", "default", None
    with open(path, "rb") as fh:
        for raw in fh:
            if not raw.endswith(b"\n") or not any(n in raw[:320] for n in NEEDLES):
                continue
            try:
                o = json.loads(raw)
                ts = timestamp(o)
            except (ValueError, KeyError):
                continue
            kind, payload = o.get("type"), o.get("payload") or {}
            ptype = payload.get("type") if isinstance(payload, dict) else None
            if kind == "turn_context":
                model, effort = payload.get("model", model), payload.get("effort", effort)
            elif kind == "event_msg" and ptype == "thread_settings_applied":
                s = payload.get("thread_settings") or {}
                model, effort = s.get("model", model), s.get("reasoning_effort", effort)
                if s.get("service_tier"):
                    tier = "priority" if s["service_tier"] == "fast" else s["service_tier"]
            elif kind == "event_msg" and ptype == "task_started":
                start = ts
            elif kind == "event_msg" and ptype in ("task_complete", "turn_aborted"):
                start = None
            elif kind == "response_item" and (
                ptype in ("function_call_output", "custom_tool_call_output")
                or (ptype == "message" and payload.get("role") == "user")
            ):
                start = ts
            elif kind == "token_usage_record":
                usage = payload.get("usage") or {}
                out = usage.get("output_tokens") or 0
                if start is not None and out > 0 and ts - start > 0.3:
                    yield (payload.get("thread_id") or thread_from_name, ts, model, effort, tier, out,
                           usage.get("reasoning_output_tokens") or 0, ts - start)
                start = None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--codex-home", default=os.path.expanduser("~/.codex"))
    ap.add_argument("--db", default=os.path.expanduser("~/Library/Application Support/CodexTPS/metrics.sqlite"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    files = sorted(glob.glob(f"{args.codex_home}/sessions/**/rollout-*.jsonl", recursive=True))
    files += sorted(glob.glob(f"{args.codex_home}/archived_sessions/rollout-*.jsonl"))

    os.makedirs(os.path.dirname(args.db), exist_ok=True)
    db = sqlite3.connect(args.db)
    db.executescript(SCHEMA)
    existing = {}
    for thread, end, out in db.execute("SELECT thread_id, end_at, output_tokens FROM responses"):
        existing.setdefault(thread, []).append((end, out))

    rows, skipped, used = [], 0, 0
    for path in files:
        found = list(responses(path))
        used += bool(found)
        for r in found:
            if any(abs(end - r[1]) < 2.5 and out == r[5] for end, out in existing.get(r[0], [])):
                skipped += 1
                continue
            rows.append(r)

    print(f"{len(files)} rollout files, {used} with responses: {len(rows)} to import, {skipped} already recorded")
    if rows:
        print(f"range {datetime.fromtimestamp(min(r[1] for r in rows)):%Y-%m-%d} … "
              f"{datetime.fromtimestamp(max(r[1] for r in rows)):%Y-%m-%d}")
    if not args.dry_run:
        with db:
            db.executemany("INSERT OR IGNORE INTO responses (thread_id, end_at, model, effort, tier, output_tokens, "
                           "reasoning_tokens, duration, ttft) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)", rows)
        print("imported, total rows:", db.execute("SELECT count(*) FROM responses").fetchone()[0])


if __name__ == "__main__":
    main()
