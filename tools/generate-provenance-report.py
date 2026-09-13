#!/usr/bin/env python3
"""
Generate a human-readable Markdown report from Epidemica's provenance
audit artifacts.

Usage:
    python3 tools/generate-provenance-report.py \
        "$tmp" \
        "$tmp/provenance-report.md"

Expected audit directory:

    scancode.json
    scanoss.json
    scanoss-copyleft.json
    ort/
      pub/
        analyzer/analyzer-result.json
        pub-license-lookup.json
      mix/
        analyzer/analyzer-result.json
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ALLOW_LICENSES = {
    "Apache-2.0",
    "MIT",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC",
}

COPYLEFT_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9])(?:AGPL|LGPL|GPL)-"
)

OTHER_REVIEW_RE = re.compile(
    r"(?i)(?:MPL-|EPL-|CDDL-|CPL-|OSL-|SSPL-|"
    r"LicenseRef|NOASSERTION|NONE)"
)


def load_json(path: Path) -> Any | None:
    if not path.is_file():
        return None

    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def md(value: Any) -> str:
    """Escape a value for a simple Markdown table cell."""
    if value is None:
        return ""

    text = str(value)
    text = text.replace("|", r"\|")
    text = text.replace("\n", " ")
    return text


def table(headers: list[str], rows: list[list[Any]]) -> str:
    if not rows:
        return "_None._\n"

    out = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]

    for row in rows:
        out.append("| " + " | ".join(md(v) for v in row) + " |")

    return "\n".join(out) + "\n"


def status_badge(status: str) -> str:
    return {
        "PASS": "✅ PASS",
        "REVIEW": "⚠️ REVIEW",
        "FAIL": "❌ FAIL",
        "INCOMPLETE": "⏸️ INCOMPLETE",
    }.get(status, status)


# ---------------------------------------------------------------------------
# ScanCode
# ---------------------------------------------------------------------------


def load_scancode_policy(repo_root: Path):
    """
    Reuse check-license-scan.py rather than duplicating its policy.
    """

    checker = repo_root / "tools" / "check-license-scan.py"

    if not checker.is_file():
        return None

    spec = importlib.util.spec_from_file_location(
        "epidemica_check_license_scan",
        checker,
    )

    if spec is None or spec.loader is None:
        return None

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def analyze_scancode(
    audit_dir: Path,
    repo_root: Path,
) -> dict[str, Any]:
    report_path = audit_dir / "scancode.json"
    report = load_json(report_path)

    result = {
        "status": "INCOMPLETE",
        "rejects": [],
        "reviews": [],
        "message": "ScanCode result is missing or unreadable.",
    }

    if report is None:
        return result

    policy = load_scancode_policy(repo_root)

    if policy is None:
        result["message"] = (
            "ScanCode result exists, but check-license-scan.py "
            "could not be loaded."
        )
        return result

    rejects = []
    reviews = []

    for entry in report.get("files", []):
        if entry.get("type") != "file":
            continue

        path = entry.get("path", "")

        if policy.excluded(path):
            continue

        for expression, score in policy.iter_detections(entry):
            if score < policy.MIN_SCORE_TO_ACT:
                continue

            verdict = policy.classify(expression)

            finding = {
                "path": path,
                "license": expression,
                "score": score,
            }

            if verdict == "reject":
                rejects.append(finding)

            elif verdict == "review":
                reviews.append(finding)

    if rejects:
        status = "FAIL"
        message = f"{len(rejects)} copyleft finding(s) in first-party source."

    elif reviews:
        status = "REVIEW"
        message = (
            f"No copyleft findings; {len(reviews)} other license "
            "finding(s) require review."
        )

    else:
        status = "PASS"
        message = "No actionable foreign/copyleft license text detected."

    return {
        "status": status,
        "rejects": rejects,
        "reviews": reviews,
        "message": message,
    }


# ---------------------------------------------------------------------------
# SCANOSS
# ---------------------------------------------------------------------------


def as_list(value: Any) -> list[Any]:
    if value is None:
        return []

    if isinstance(value, list):
        return value

    return [value]


def analyze_scanoss(audit_dir: Path) -> dict[str, Any]:
    path = audit_dir / "scanoss.json"
    raw = load_json(path)

    if raw is None:
        return {
            "status": "INCOMPLETE",
            "total_matches": 0,
            "copyleft": [],
            "message": (
                "No usable SCANOSS result. The scan may have failed "
                "or been rate-limited."
            ),
        }

    matches = []
    copyleft = []

    if not isinstance(raw, dict):
        return {
            "status": "INCOMPLETE",
            "total_matches": 0,
            "copyleft": [],
            "message": "Unexpected SCANOSS result format.",
        }

    for local_path, entries in raw.items():
        if not isinstance(entries, list):
            continue

        for item in entries:
            if not isinstance(item, dict):
                continue

            if item.get("id") not in {"file", "snippet"}:
                continue

            licenses = []

            for lic in as_list(item.get("licenses")):
                if isinstance(lic, dict):
                    value = (
                        lic.get("spdxid")
                        or lic.get("name")
                        or "UNKNOWN"
                    )
                else:
                    value = str(lic)

                licenses.append(value)

            purls = [
                str(value)
                for value in as_list(item.get("purl"))
                if value
            ]

            finding = {
                "local_file": local_path,
                "type": item.get("id", ""),
                "local_lines": item.get("lines", "unknown"),
                "matched": item.get("matched", "unknown"),
                "component": item.get("component", "unknown"),
                "version": item.get("version", "unknown"),
                "upstream_file": item.get("file", "unknown"),
                "upstream_lines": item.get("oss_lines", "unknown"),
                "purl": ", ".join(purls),
                "license": " AND ".join(licenses) if licenses else "UNKNOWN",
            }

            matches.append(finding)

            if any(COPYLEFT_RE.search(lic) for lic in licenses):
                copyleft.append(finding)

    if copyleft:
        status = "REVIEW"
        message = (
            f"{len(copyleft)} similarity match(es) against "
            "copyleft-licensed components require provenance review."
        )
    else:
        status = "PASS"
        message = (
            f"{len(matches)} file/snippet match(es) found; "
            "none identify a copyleft-licensed component."
        )

    return {
        "status": status,
        "total_matches": len(matches),
        "copyleft": copyleft,
        "message": message,
    }


# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------


def simple_spdx_tokens(expression: str) -> list[str]:
    value = expression

    for char in "()":
        value = value.replace(char, " ")

    value = re.sub(r"\bAND\b", " ", value)
    value = re.sub(r"\bOR\b", " ", value)

    return [
        token
        for token in value.split()
        if token
    ]


def classify_dependency_license(expression: str) -> tuple[str, str]:
    if not expression or expression == "UNKNOWN":
        return "REVIEW", "unknown"

    if COPYLEFT_RE.search(expression):
        return "REVIEW", "copyleft"

    if OTHER_REVIEW_RE.search(expression):
        return "REVIEW", "policy-review"

    if re.search(r"\bWITH\b", expression):
        return "REVIEW", "license-exception"

    tokens = simple_spdx_tokens(expression)

    if tokens and all(token in ALLOW_LICENSES for token in tokens):
        return "ALLOW", "permissive"

    return "REVIEW", "unapproved"


def analyze_dependencies(
    audit_dir: Path,
    repo_root: Path,
) -> dict[str, Any]:
    pub_path = (
        audit_dir
        / "ort"
        / "pub"
        / "analyzer"
        / "analyzer-result.json"
    )

    mix_path = (
        audit_dir
        / "ort"
        / "mix"
        / "analyzer"
        / "analyzer-result.json"
    )

    lookup_path = (
        audit_dir
        / "ort"
        / "pub"
        / "pub-license-lookup.json"
    )

    pub = load_json(pub_path)
    mix = load_json(mix_path)
    lookup = load_json(lookup_path) or {}

    inputs = []

    if pub:
        inputs.append(("Pub", pub))

    if mix:
        inputs.append(("Mix", mix))

    if not inputs:
        return {
            "status": "INCOMPLETE",
            "packages": [],
            "review": [],
            "allow": [],
            "coverage_gaps": [
                "No usable ORT analyzer results were found."
            ],
            "message": "Dependency analysis is missing.",
        }

    packages_by_id: dict[str, dict[str, Any]] = {}

    for ecosystem, result in inputs:
        packages = (
            result
            .get("analyzer", {})
            .get("result", {})
            .get("packages", [])
        )

        for package in packages:
            package_id = package.get("id", "unknown")

            expression = (
                package
                .get("declared_licenses_processed", {})
                .get("spdx_expression")
            )

            source = "ORT"

            if not expression:
                lookup_entry = lookup.get(package_id, {})

                expression = lookup_entry.get("license_expression")

                if expression:
                    source = "PUB-LICENSE"

            if not expression:
                raw = package.get("declared_licenses") or []

                if raw:
                    expression = " / ".join(raw)
                    source = "ORT-RAW"

            if not expression:
                expression = "UNKNOWN"
                source = "UNKNOWN"

            verdict, reason = classify_dependency_license(expression)

            candidate = {
                "ecosystem": ecosystem,
                "id": package_id,
                "purl": package.get("purl", ""),
                "license": expression,
                "license_source": source,
                "verdict": verdict,
                "reason": reason,
            }

            # If the same package is encountered twice, prefer a known
            # license over UNKNOWN.
            existing = packages_by_id.get(package_id)

            if (
                existing is None
                or (
                    existing["license"] == "UNKNOWN"
                    and expression != "UNKNOWN"
                )
            ):
                packages_by_id[package_id] = candidate

    packages = sorted(
        packages_by_id.values(),
        key=lambda p: p["id"].lower(),
    )

    review = [p for p in packages if p["verdict"] == "REVIEW"]
    allow = [p for p in packages if p["verdict"] == "ALLOW"]

    coverage_gaps = []

    if pub is None:
        coverage_gaps.append("Pub dependency analysis is missing.")

    if mix is None:
        coverage_gaps.append("Mix dependency analysis is missing.")

    python_manifests = [
        repo_root / "models" / "pyproject.toml",
        repo_root / "analysis" / "pyproject.toml",
    ]

    existing_python = [
        path.relative_to(repo_root).as_posix()
        for path in python_manifests
        if path.is_file()
    ]

    if existing_python:
        coverage_gaps.append(
            "Python manifests exist but the current dependency audit "
            "does not resolve Python dependencies: "
            + ", ".join(existing_python)
        )

    # Detect Pub's intentionally restricted native coverage.
    if pub:
        pub_options = (
            pub
            .get("analyzer", {})
            .get("config", {})
            .get("package_managers", {})
            .get("Pub", {})
            .get("options", {})
        )

        if str(pub_options.get("pubDependenciesOnly", "")).lower() == "true":
            coverage_gaps.append(
                "Pub analysis uses pubDependenciesOnly=true; native "
                "Android Gradle / iOS CocoaPods dependencies are outside "
                "this report."
            )

    if coverage_gaps:
        status = "INCOMPLETE"

    elif review:
        status = "REVIEW"

    else:
        status = "PASS"

    message = (
        f"{len(packages)} dependencies: "
        f"{len(allow)} allowed, {len(review)} requiring review."
    )

    if coverage_gaps:
        message += f" {len(coverage_gaps)} coverage gap(s)."

    return {
        "status": status,
        "packages": packages,
        "review": review,
        "allow": allow,
        "coverage_gaps": coverage_gaps,
        "message": message,
    }


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------


def overall_status(statuses: list[str]) -> str:
    if "FAIL" in statuses:
        return "FAIL"

    if "INCOMPLETE" in statuses:
        return "INCOMPLETE"

    if "REVIEW" in statuses:
        return "REVIEW"

    return "PASS"


def generate_report(
    audit_dir: Path,
    repo_root: Path,
) -> str:
    scancode = analyze_scancode(audit_dir, repo_root)
    scanoss = analyze_scanoss(audit_dir)
    dependencies = analyze_dependencies(audit_dir, repo_root)

    overall = overall_status(
        [
            scancode["status"],
            scanoss["status"],
            dependencies["status"],
        ]
    )

    revision = "unknown"

    for candidate in [
        audit_dir / "ort/pub/analyzer/analyzer-result.json",
        audit_dir / "ort/mix/analyzer/analyzer-result.json",
    ]:
        obj = load_json(candidate)

        if obj:
            revision = (
                obj
                .get("repository", {})
                .get("vcs", {})
                .get("revision")
                or revision
            )

            if revision != "unknown":
                break

    generated = datetime.now(timezone.utc).strftime(
        "%Y-%m-%d %H:%M:%S UTC"
    )

    lines = []

    lines.append("# Epidemica Provenance Audit Report")
    lines.append("")
    lines.append(f"**Overall status:** {status_badge(overall)}")
    lines.append("")
    lines.append(f"**Generated:** {generated}  ")
    lines.append(f"**Git revision:** `{revision}`")
    lines.append("")

    # Executive summary
    lines.append("## Executive summary")
    lines.append("")

    lines.append(
        table(
            ["Check", "Status", "Summary"],
            [
                [
                    "First-party ScanCode",
                    status_badge(scancode["status"]),
                    scancode["message"],
                ],
                [
                    "SCANOSS provenance",
                    status_badge(scanoss["status"]),
                    scanoss["message"],
                ],
                [
                    "Dependency licenses",
                    status_badge(dependencies["status"]),
                    dependencies["message"],
                ],
            ],
        )
    )

    # Action items
    lines.append("## Action items")
    lines.append("")

    actions = []

    for finding in scancode["rejects"]:
        actions.append(
            f"**BLOCKING:** inspect ScanCode copyleft finding in "
            f"`{finding['path']}` — `{finding['license']}`."
        )

    for finding in scancode["reviews"]:
        actions.append(
            f"Review ScanCode finding in `{finding['path']}` — "
            f"`{finding['license']}`."
        )

    if scanoss["status"] == "INCOMPLETE":
        actions.append(
            "**Re-run SCANOSS.** No usable result was produced; "
            "this can occur when the public OSSKB API is rate-limited."
        )

    for finding in scanoss["copyleft"]:
        actions.append(
            f"Review SCANOSS similarity in "
            f"`{finding['local_file']}:{finding['local_lines']}` "
            f"against `{finding['component']}` "
            f"({finding['license']})."
        )

    for package in dependencies["review"]:
        actions.append(
            f"Review dependency `{package['id']}` — "
            f"`{package['license']}` "
            f"({package['reason']})."
        )

    for gap in dependencies["coverage_gaps"]:
        actions.append(f"Coverage gap: {gap}")

    if actions:
        for action in actions:
            lines.append(f"- {action}")
    else:
        lines.append("_No automated action items._")

    lines.append("")

    # ScanCode
    lines.append("## 1. ScanCode — first-party source")
    lines.append("")
    lines.append(f"**Status:** {status_badge(scancode['status'])}")
    lines.append("")
    lines.append(scancode["message"])
    lines.append("")

    scan_rows = []

    for f in scancode["rejects"]:
        scan_rows.append(
            [
                "REJECT",
                f["path"],
                f["license"],
                f"{f['score']:.0f}",
            ]
        )

    for f in scancode["reviews"]:
        scan_rows.append(
            [
                "REVIEW",
                f["path"],
                f["license"],
                f"{f['score']:.0f}",
            ]
        )

    lines.append(
        table(
            ["Verdict", "File", "License", "Score"],
            scan_rows,
        )
    )

    if (audit_dir / "scancode.json").is_file():
        lines.append("Raw artifact: [`scancode.json`](./scancode.json)")
        lines.append("")

    # SCANOSS
    lines.append("## 2. SCANOSS — source provenance")
    lines.append("")
    lines.append(f"**Status:** {status_badge(scanoss['status'])}")
    lines.append("")
    lines.append(scanoss["message"])
    lines.append("")

    scanoss_rows = []

    for f in scanoss["copyleft"]:
        scanoss_rows.append(
            [
                f["local_file"],
                f["local_lines"],
                f["matched"],
                f"{f['component']} {f['version']}",
                f["license"],
                f["upstream_file"],
                f["upstream_lines"],
            ]
        )

    lines.append(
        table(
            [
                "Local file",
                "Lines",
                "Match",
                "Component",
                "License",
                "Upstream file",
                "Upstream lines",
            ],
            scanoss_rows,
        )
    )

    lines.append(
        f"Total SCANOSS file/snippet matches: "
        f"**{scanoss['total_matches']}**."
    )
    lines.append("")

    if (audit_dir / "scanoss.json").is_file():
        lines.append("Raw artifact: [`scanoss.json`](./scanoss.json)")
        lines.append("")

    # Dependencies
    lines.append("## 3. Dependency licenses")
    lines.append("")
    lines.append(
        f"**Status:** {status_badge(dependencies['status'])}"
    )
    lines.append("")
    lines.append(dependencies["message"])
    lines.append("")

    dep_rows = [
        [
            p["id"],
            p["license"],
            p["license_source"],
            p["reason"],
        ]
        for p in dependencies["review"]
    ]

    lines.append("### Dependencies requiring review")
    lines.append("")
    lines.append(
        table(
            ["Package", "License", "Source", "Reason"],
            dep_rows,
        )
    )

    allowed_counts = Counter(
        p["license"]
        for p in dependencies["allow"]
    )

    lines.append("### Allowed dependency summary")
    lines.append("")

    lines.append(
        table(
            ["License", "Packages"],
            [
                [license_name, count]
                for license_name, count
                in sorted(allowed_counts.items())
            ],
        )
    )

    lines.append(
        f"Allowed dependencies: **{len(dependencies['allow'])}**  "
    )
    lines.append(
        f"Dependencies requiring review: "
        f"**{len(dependencies['review'])}**"
    )
    lines.append("")

    # Coverage
    lines.append("## Coverage and limitations")
    lines.append("")

    if dependencies["coverage_gaps"]:
        for gap in dependencies["coverage_gaps"]:
            lines.append(f"- **Coverage gap:** {gap}")

    else:
        lines.append("- No dependency-analysis coverage gaps detected.")

    lines.extend(
        [
            "- ScanCode checks first-party files for license / copyright "
            "signals; a clean result is not proof of independent authorship.",
            "- SCANOSS similarity findings are provenance leads, not proof "
            "that source was copied from the matched repository.",
            "- Dependency licenses come from ORT package metadata or the "
            "published Pub package LICENSE/COPYING file. Dependency source "
            "trees are not being fully scanned.",
            "- A REVIEW result is not automatically incompatible with "
            "Apache-2.0; it means a human compatibility / provenance "
            "decision is required.",
        ]
    )

    lines.append("")

    # Artifacts
    lines.append("## Audit artifacts")
    lines.append("")

    artifact_paths = [
        "scancode.json",
        "scanoss.json",
        "scanoss-copyleft.json",
        "ort/pub/analyzer/analyzer-result.json",
        "ort/pub/pub-license-lookup.json",
        "ort/mix/analyzer/analyzer-result.json",
    ]

    for rel in artifact_paths:
        path = audit_dir / rel

        if path.is_file():
            lines.append(f"- [`{rel}`](./{rel})")
        else:
            lines.append(f"- `{rel}` — **missing**")

    lines.append("")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "audit_dir",
        type=Path,
        help="Root of the provenance audit artifacts",
    )

    parser.add_argument(
        "output",
        type=Path,
        nargs="?",
        help="Markdown output path",
    )

    args = parser.parse_args()

    audit_dir = args.audit_dir.resolve()

    if not audit_dir.is_dir():
        print(
            f"error: audit directory does not exist: {audit_dir}"
        )
        return 2

    repo_root = Path(__file__).resolve().parent.parent

    output = (
        args.output.resolve()
        if args.output
        else audit_dir / "provenance-report.md"
    )

    report = generate_report(
        audit_dir=audit_dir,
        repo_root=repo_root,
    )

    output.write_text(report)

    print(f"Provenance report -> {output}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())