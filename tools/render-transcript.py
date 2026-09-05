#!/usr/bin/env python3
"""Render a Copilot session transcript as readable Markdown.

The raw `.jsonl` is a machine log: nine megabytes of interleaved events, most of it tool arguments
and captured terminal output. This keeps the conversation — every message from both sides, in full —
and reduces each tool call to one line saying what was run, so the record stays about the reasoning
rather than the scrollback.

    python3 tools/render-transcript.py <session.jsonl> <out.md>
    python3 tools/render-transcript.py <session.jsonl> <out.md> --since 2026-08-12 --until 2026-08-14

Why this exists: see docs/concepts/licensing.md#building-your-own-module-with-an-ai-coding-agent —
a rendered transcript is evidence of the human review, direction and iterative refinement behind
AI-assisted work, which is the criterion copyright authorities look for when assessing human
authorship of a piece of software. It is a record, not a legal opinion; it doesn't make anything
copyrightable by itself.
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone

# Long enough to identify a command, short enough that the file stays readable.
ARG_LIMIT = 220


def parse_timestamp(raw: str | None) -> datetime | None:
    """Parses an event's own ISO-8601 timestamp, or a --since/--until boundary typed by a user.

    Event timestamps always carry a UTC 'Z' suffix. A boundary typed on the command line often
    won't (`--since 2026-08-12`) — treated as UTC too, since that's what it's being compared against.
    """
    if not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def when(raw: str | None) -> str:
    parsed = parse_timestamp(raw)
    return parsed.strftime("%Y-%m-%d %H:%M") if parsed else (raw or "")


def one_line(text: str, limit: int = ARG_LIMIT) -> str:
    flat = " ".join(str(text).split())
    return flat if len(flat) <= limit else flat[: limit - 1] + "…"


def describe(name: str, arguments: str) -> str:
    """The interesting part of a tool call, which differs by tool."""
    try:
        args = json.loads(arguments) if isinstance(arguments, str) else (arguments or {})
    except json.JSONDecodeError:
        return one_line(arguments)

    if not isinstance(args, dict):
        return one_line(str(args))

    for key in ("command", "query", "filePath", "path", "url", "prompt", "description"):
        if key in args and args[key]:
            return one_line(args[key])

    if "replacements" in args:
        files = {r.get("filePath", "?") for r in args["replacements"] if isinstance(r, dict)}
        return one_line(", ".join(sorted(files)))

    return one_line(json.dumps(args))


def load_events(source: str) -> list[dict]:
    events = []
    with open(source, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def render(events: list[dict], since: datetime | None, until: datetime | None) -> tuple[str, int, int]:
    started = next((e for e in events if e.get("type") == "session.start"), None)
    all_stamps = [e.get("timestamp") for e in events if e.get("timestamp")]

    if since or until:
        events = [
            e
            for e in events
            if e.get("type") == "session.start"
            or (
                (ts := parse_timestamp(e.get("timestamp"))) is not None
                and (since is None or ts >= since)
                and (until is None or ts <= until)
            )
        ]

    stamps = [e.get("timestamp") for e in events if e.get("timestamp") and e.get("type") != "session.start"]
    users = sum(1 for e in events if e.get("type") == "user.message")
    tools = sum(1 for e in events if e.get("type") == "tool.execution_start")

    out: list[str] = []
    out.append("# Epidemica — development transcript\n")
    out.append(
        "The full working conversation behind this repository, rendered from the Copilot session "
        "log. Every message from both sides is here in full; tool calls are reduced to one line "
        "each, because the value of this record is the reasoning, not the scrollback.\n"
    )
    if started:
        data = started.get("data", {})
        out.append(f"- **Session:** `{data.get('sessionId', '?')}`")
        out.append(f"- **Producer:** {data.get('producer', '?')} {data.get('copilotVersion', '')}".rstrip())
    if all_stamps:
        out.append(f"- **Full session span:** {when(min(all_stamps))} to {when(max(all_stamps))} UTC")
    if since or until:
        lo = when(since.isoformat()) if since else "the start"
        hi = when(until.isoformat()) if until else "the end"
        out.append(f"- **Rendered range:** {lo} to {hi} UTC")
    out.append(f"- **Exchanges:** {users} from the user, {tools} tool calls\n")
    out.append("---\n")

    exchange = 0
    pending: dict[str, str] = {}

    for event in events:
        kind = event.get("type")
        data = event.get("data") or {}

        if kind == "user.message":
            exchange += 1
            content = (data.get("content") or "").strip()
            out.append(f"\n## {exchange}. User — {when(event.get('timestamp'))}\n")
            out.append(content if content else "_(no text)_")
            out.append("")

        elif kind == "assistant.message":
            content = (data.get("content") or "").strip()
            requests = data.get("toolRequests") or []

            if content:
                out.append("\n**Assistant**\n")
                out.append(content)
                out.append("")

            for request in requests:
                name = request.get("name", "?")
                detail = describe(name, request.get("arguments", ""))
                pending[request.get("toolCallId", "")] = name
                out.append(f"> `{name}` — {detail}" if detail else f"> `{name}`")

        elif kind == "tool.execution_complete":
            # This log format signals failure with `success: false` and carries no error message —
            # earlier versions of this script looked for `error`/`errorMessage` fields that this
            # schema does not have, which silently matched nothing. Confirmed against a real
            # transcript before fixing: don't reintroduce the old field names without re-checking.
            if data.get("success") is False:
                name = pending.get(data.get("toolCallId", ""), "tool")
                out.append(f">\n> ⚠️ `{name}` failed")

    return "\n".join(out).rstrip() + "\n", exchange, tools


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Render a Copilot session .jsonl transcript as readable Markdown.",
    )
    parser.add_argument("source", help="path to the session .jsonl")
    parser.add_argument("destination", help="path to write the rendered Markdown")
    parser.add_argument(
        "--since",
        metavar="TIMESTAMP",
        help="only render events at or after this time (ISO-8601, e.g. 2026-08-12 or "
        "2026-08-12T14:00:00Z; naive times are treated as UTC)",
    )
    parser.add_argument(
        "--until",
        metavar="TIMESTAMP",
        help="only render events at or before this time (same format as --since)",
    )
    args = parser.parse_args()

    since = parse_timestamp(args.since) if args.since else None
    if args.since and since is None:
        raise SystemExit(f"--since: could not parse {args.since!r} as an ISO-8601 timestamp")
    until = parse_timestamp(args.until) if args.until else None
    if args.until and until is None:
        raise SystemExit(f"--until: could not parse {args.until!r} as an ISO-8601 timestamp")
    if since and until and since > until:
        raise SystemExit("--since must be before --until")

    events = load_events(args.source)
    rendered, exchange, tools = render(events, since, until)

    with open(args.destination, "w", encoding="utf-8") as handle:
        handle.write(rendered)

    print(f"{args.destination}: {exchange} exchanges, {tools} tool calls")


if __name__ == "__main__":
    main()
