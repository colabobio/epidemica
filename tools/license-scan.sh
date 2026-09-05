#!/usr/bin/env bash
# Scans Epidemica's own source for embedded license text, SPDX identifiers, and copyright
# notices that do not belong to this project — the signal that a copyleft-licensed snippet
# (verbatim or lightly modified) was pulled in from somewhere else, by a human or an agent.
#
# What this catches: license headers, boilerplate license text, and copyright statements
# detected by ScanCode's text-matching engine against the SPDX license list.
# What this does NOT catch: functionally-equivalent code that was rewritten or paraphrased
# closely enough to escape text matching, or logic copied without any license text attached.
# See docs/adr/0016-automated-license-and-provenance-scanning.md for what this is and is not
# a substitute for.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# ScanCode computes a common ancestor across every path given in ONE invocation and walks the
# whole thing — passing "models/src" and "analysis/src" together silently pulls in whatever sits
# between them, which is the repository root, which is every vendored dependency tree we have
# (.venv, deps/, build artifacts, gigabytes of it). This bit us during development: a scan that
# "completed" in under a minute for one path took ten-plus minutes and quietly swept in Pillow,
# SQLAlchemy, Phoenix's own deps/, and every other third-party LICENSE file once two sibling
# project directories were scanned in the same command. The fix is not a cleverer --ignore
# pattern: it is never scanning more than one project directory per invocation.
scan_paths=(
  contracts
  server/lib server/config server/priv/repo server/mix.exs
  packages/*/lib packages/*/test packages/*/pubspec.yaml
  apps/*/lib apps/*/test apps/*/pubspec.yaml
  models/src models/pyproject.toml
  analysis/src analysis/tests analysis/pyproject.toml
  docs .claude AGENTS.md CLAUDE.md README.md NOTICE LICENSE studies deploy
)

existing=()
for p in "${scan_paths[@]}"; do
  [[ -e "$p" ]] && existing+=("$p")
done

out="${1:-/tmp/epidemica-license-scan.json}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "Scanning ${#existing[@]} paths, one ScanCode invocation per path (see the comment above" \
     "for why they cannot be batched). This warms ScanCode's license index on the first call;" \
     "expect the first invocation to take a couple of minutes, the rest to be fast."

i=0
part_files=()
part_roots=()
for p in "${existing[@]}"; do
  i=$((i + 1))
  part="$work_dir/part-$i.json"
  scancode --license --copyright -n 4 --ignore "*/__pycache__/*" --ignore "*.pyc" \
    --json "$part" "$p" > /dev/null
  part_files+=("$part")
  part_roots+=("$p")
done

python3 - "$out" "${#part_files[@]}" "${part_files[@]}" "${part_roots[@]}" <<'PY'
import json
import os
import sys

out_path = sys.argv[1]
n = int(sys.argv[2])
parts = sys.argv[3:3 + n]
roots = sys.argv[3 + n:3 + 2 * n]

merged = {"headers": [], "files": []}
for part, root in zip(parts, roots):
    data = json.loads(open(part).read())
    merged["headers"].extend(data.get("headers", []))
    # ScanCode reports paths relative to the basename of the scanned root, so a scan rooted at
    # "packages/epidemica_core/lib" reports "lib/foo.dart" rather than the full repo-relative
    # path. Reconstruct the real path so findings are unambiguous once results are merged.
    prefix = os.path.dirname(root)
    for entry in data.get("files", []):
        if prefix:
            entry["path"] = f"{prefix}/{entry['path']}"
        merged["files"].append(entry)

with open(out_path, "w") as f:
    json.dump(merged, f, indent=2)
print(f"{len(merged['files'])} file/directory entries across {len(parts)} scans -> {out_path}")
PY

echo
echo "Run tools/check-license-scan.py \"$out\" to apply the allow-list and get a pass/fail."

