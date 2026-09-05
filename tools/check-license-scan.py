#!/usr/bin/env python3
"""Applies Epidemica's license allow-list (ADR-0009, ADR-0016) to a ScanCode Toolkit JSON report.

This is a policy filter, not a license detector — all the detection is ScanCode's. What this adds:

  - Excludes files that are expected to *discuss* licenses by name (docs/, ADRs, this tool itself)
    from the check, so an ADR comparing GPL-3.0 against Apache-2.0 in a table does not fail its own
    license scan.
  - Distinguishes ALLOW (Apache-2.0, MIT, BSD-2/3-Clause, ISC — everything already compatible with
    ADR-0009's Apache-2.0 choice) from REJECT (any GPL/AGPL/LGPL family match) from REVIEW (anything
    else ScanCode matched with meaningful confidence: unknown, proprietary-looking, or a license we
    have not made a policy call on).
  - Only REJECT fails the run. REVIEW is printed for a human to look at and does not block — a
    scanner that blocks every merge on a low-confidence guess trains people to ignore it.

See docs/adr/0016-automated-license-and-provenance-scanning.md for what this catches and, just as
importantly, what it structurally cannot: code that was rewritten closely enough to escape text
matching entirely. This tool finds embedded license text and copyleft notices; it does not find
"logic that resembles someone else's."
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

# Paths where naming a license in prose is the entire point (an ADR comparing options,
# a NOTICE file whose whole purpose is listing third-party attributions, this checker's own
# docstring) and must not be treated as contamination.
EXCLUDED_PREFIXES = (
    "docs/",
    "README.md",
    "NOTICE",
    "LICENSE",
    "tools/license-scan.sh",
    "tools/check-license-scan.py",
)

ALLOW = {
    "apache-2.0",
    "mit",
    "bsd-simplified",
    "bsd-new",
    "bsd-3-clause",
    "bsd-2-clause",
    "isc",
    "cc-by-4.0",  # ADR-0009: docs/schemas are CC-BY-4.0, some fixtures may carry that text
}
REJECT_PREFIXES = ("gpl-", "agpl-", "lgpl-")

# Below this ScanCode match score (0-100), a "detection" is usually a stray keyword
# (a comment saying "no GPL code here" matches "gpl") rather than actual license text.
MIN_SCORE_TO_ACT = 70.0


def excluded(path: str) -> bool:
    return any(path == p or path.startswith(p) for p in EXCLUDED_PREFIXES)


def classify(expression: str) -> str:
    key = expression.lower()
    if key in ALLOW:
        return "allow"
    if any(key.startswith(p) or f"({p}" in key for p in REJECT_PREFIXES):
        return "reject"
    return "review"


def iter_detections(file_entry: dict):
    """ScanCode's per-file license schema has changed across major versions; read both shapes."""
    for det in file_entry.get("license_detections", []):
        expr = det.get("license_expression") or det.get("license_expression_spdx")
        score = det.get("matches", [{}])[0].get("score", 100.0) if det.get("matches") else 100.0
        if expr:
            yield expr, score
    for lic in file_entry.get("licenses", []):  # older ScanCode releases
        if lic.get("key"):
            yield lic["key"], lic.get("score", 100.0)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <scancode-report.json>", file=sys.stderr)
        return 2

    report = json.loads(Path(argv[1]).read_text())
    rejects: list[tuple[str, str, float]] = []
    reviews: list[tuple[str, str, float]] = []

    for entry in report.get("files", []):
        if entry.get("type") != "file":
            continue
        path = entry["path"]
        if excluded(path):
            continue
        for expr, score in iter_detections(entry):
            if score < MIN_SCORE_TO_ACT:
                continue
            verdict = classify(expr)
            if verdict == "reject":
                rejects.append((path, expr, score))
            elif verdict == "review":
                reviews.append((path, expr, score))

    if reviews:
        print(f"REVIEW — {len(reviews)} match(es) not on the allow-list, not auto-rejected either:")
        for path, expr, score in reviews:
            print(f"  {path}: {expr} (score {score:.0f})")
        print()

    if rejects:
        print(f"REJECT — {len(rejects)} copyleft match(es) in project source:")
        for path, expr, score in rejects:
            print(f"  {path}: {expr} (score {score:.0f})")
        print()
        print("A GPL/AGPL/LGPL match in our own source is the signal this tool exists to catch.")
        print("Before removing the flagged code: confirm whether it was written from scratch and")
        print("merely mentions the license in a comment, or was actually derived from copyleft code.")
        return 1

    print("No copyleft license text detected in project source. This is not a guarantee of")
    print("non-infringement — see the limitations in docs/adr/0016 — only that no known copyleft")
    print("license text or SPDX identifier was found embedded in the files scanned.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
