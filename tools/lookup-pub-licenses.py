#!/usr/bin/env python3
"""
Resolve license identifiers for Pub dependencies in an ORT Analyzer result.

For each Pub package:
  - Use ORT's exact source_artifact URL.
  - Verify the archive SHA-256 when available.
  - Extract only root-level LICENSE / COPYING-style files.
  - Run ScanCode once over those extracted license files.
  - Write a compact JSON license lookup.

This does NOT scan dependency source code.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath


LICENSE_NAME_RE = re.compile(
    r"^(LICENSE|LICENCE|COPYING|COPYRIGHT|UNLICENSE)(?:\..*)?$",
    re.IGNORECASE,
)


def download(url: str) -> bytes:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "epidemica-license-audit/1.0"},
    )
    with urllib.request.urlopen(req, timeout=60) as response:
        return response.read()


def iter_scancode_expressions(file_entry: dict):
    """Support current and older ScanCode per-file schemas."""

    for detection in file_entry.get("license_detections", []):
        expr = (
            detection.get("license_expression_spdx")
            or detection.get("license_expression")
        )
        if expr:
            yield expr

    for license_info in file_entry.get("licenses", []):
        expr = (
            license_info.get("spdx_license_key")
            or license_info.get("key")
        )
        if expr:
            yield expr


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "analyzer_result",
        type=Path,
        help="ORT Pub analyzer-result.json",
    )
    parser.add_argument(
        "output",
        type=Path,
        help="Output pub-license-lookup.json",
    )
    args = parser.parse_args()

    if not args.analyzer_result.is_file():
        print(
            f"error: analyzer result not found: {args.analyzer_result}",
            file=sys.stderr,
        )
        return 2

    analyzer = json.loads(args.analyzer_result.read_text())

    packages = [
        p
        for p in analyzer.get("analyzer", {})
        .get("result", {})
        .get("packages", [])
        if p.get("id", "").startswith("Pub::")
    ]

    results: dict[str, dict] = {}

    with tempfile.TemporaryDirectory(prefix="epidemica-pub-licenses-") as tmp:
        tmp_path = Path(tmp)
        license_root = tmp_path / "licenses"
        license_root.mkdir()

        # Maps our safe temporary directory names back to ORT package IDs.
        key_to_id: dict[str, str] = {}

        for number, package in enumerate(packages, start=1):
            package_id = package["id"]
            artifact = package.get("source_artifact") or {}
            url = artifact.get("url") or ""
            hash_info = artifact.get("hash") or {}
            expected_hash = hash_info.get("value") or ""
            hash_algorithm = (hash_info.get("algorithm") or "").upper()

            result = {
                "purl": package.get("purl", ""),
                "source_url": url,
                "license_files": [],
                "license_expressions": [],
                "license_expression": None,
                "status": "pending",
            }
            results[package_id] = result

            # SDK packages such as Pub::flutter:0.0.0 may not have a
            # published source artifact in the ORT result.
            if not url:
                result["status"] = "no-source-artifact"
                print(f"REVIEW  {package_id}: no source artifact")
                continue

            print(f"FETCH   {package_id}")

            try:
                archive = download(url)
            except Exception as exc:
                result["status"] = "download-error"
                result["error"] = str(exc)
                print(f"ERROR   {package_id}: {exc}", file=sys.stderr)
                continue

            # Verify that we are auditing exactly the artifact ORT resolved.
            if expected_hash and hash_algorithm == "SHA-256":
                actual_hash = hashlib.sha256(archive).hexdigest()

                if actual_hash.lower() != expected_hash.lower():
                    result["status"] = "hash-mismatch"
                    result["expected_sha256"] = expected_hash
                    result["actual_sha256"] = actual_hash
                    print(
                        f"ERROR   {package_id}: SHA-256 mismatch",
                        file=sys.stderr,
                    )
                    continue

            try:
                with tarfile.open(
                    fileobj=io.BytesIO(archive),
                    mode="r:gz",
                ) as tf:
                    candidates = []

                    for member in tf.getmembers():
                        if not member.isfile():
                            continue

                        path = PurePosixPath(member.name)

                        if LICENSE_NAME_RE.match(path.name):
                            candidates.append((len(path.parts), member))

                    if not candidates:
                        result["status"] = "no-license-file"
                        print(
                            f"REVIEW  {package_id}: no LICENSE/COPYING file"
                        )
                        continue

                    # A package archive might contain license files in examples
                    # or bundled third-party directories. Prefer the shallowest
                    # license files, i.e. the package's own root license.
                    min_depth = min(depth for depth, _ in candidates)
                    candidates = [
                        member
                        for depth, member in candidates
                        if depth == min_depth
                    ]

                    key = f"pkg-{number:04d}"
                    key_to_id[key] = package_id

                    package_dir = license_root / key
                    package_dir.mkdir()

                    for index, member in enumerate(candidates, start=1):
                        extracted = tf.extractfile(member)

                        if extracted is None:
                            continue

                        original_name = PurePosixPath(member.name).name
                        output_name = f"{index:02d}-{original_name}"

                        (package_dir / output_name).write_bytes(
                            extracted.read()
                        )

                        result["license_files"].append(member.name)

            except (tarfile.TarError, OSError) as exc:
                result["status"] = "archive-error"
                result["error"] = str(exc)
                print(f"ERROR   {package_id}: {exc}", file=sys.stderr)

        if key_to_id:
            report_path = tmp_path / "scancode.json"

            print()
            print(
                f"Running ScanCode over license files from "
                f"{len(key_to_id)} Pub packages..."
            )

            try:
                subprocess.run(
                    [
                        "scancode",
                        "--license",
                        "--json",
                        str(report_path),
                        str(license_root),
                    ],
                    check=True,
                    stdout=subprocess.DEVNULL,
                )
            except FileNotFoundError:
                print(
                    "error: scancode not found; activate the license-scan "
                    "environment first",
                    file=sys.stderr,
                )
                return 2
            except subprocess.CalledProcessError as exc:
                print(
                    f"error: ScanCode failed with exit code {exc.returncode}",
                    file=sys.stderr,
                )
                return 1

            report = json.loads(report_path.read_text())

            expressions: dict[str, set[str]] = {
                package_id: set()
                for package_id in key_to_id.values()
            }

            for file_entry in report.get("files", []):
                if file_entry.get("type") != "file":
                    continue

                parts = PurePosixPath(
                    file_entry.get("path", "")
                ).parts

                key = next(
                    (part for part in parts if part in key_to_id),
                    None,
                )

                if key is None:
                    continue

                package_id = key_to_id[key]

                expressions[package_id].update(
                    iter_scancode_expressions(file_entry)
                )

            for package_id, found in expressions.items():
                result = results[package_id]
                ordered = sorted(found)

                result["license_expressions"] = ordered

                if not ordered:
                    result["status"] = "no-license-detection"

                elif len(ordered) == 1:
                    result["license_expression"] = ordered[0]
                    result["status"] = "ok"

                else:
                    # Multiple independent license texts means all of them
                    # deserve review. AND is deliberately conservative.
                    result["license_expression"] = " AND ".join(ordered)
                    result["status"] = "multiple-license-texts"

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(results, indent=2, sort_keys=True) + "\n"
    )

    ok = sum(
        1
        for result in results.values()
        if result["status"] == "ok"
    )

    review = len(results) - ok

    print()
    print(f"Pub license lookup complete: {len(results)} packages")
    print(f"Resolved: {ok}")
    print(f"Review:   {review}")
    print(f"Output:   {args.output}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())