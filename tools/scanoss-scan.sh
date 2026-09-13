# tools/scanoss-scan.sh
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scan_paths=(
  contracts
  server/lib server/config server/priv/repo server/mix.exs
  packages/*/lib packages/*/test packages/*/pubspec.yaml
  apps/*/lib apps/*/test apps/*/pubspec.yaml
  models/src models/pyproject.toml
  analysis/src analysis/tests analysis/pyproject.toml
  docs .claude AGENTS.md CLAUDE.md README.md NOTICE LICENSE studies deploy
)

out="${1:-/tmp/epidemica-scanoss.json}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

file_list="$work_dir/files.txt"

for p in "${scan_paths[@]}"; do
  [[ -e "$p" ]] || continue

  if [[ -f "$p" ]]; then
    printf '%s\n' "$p"
  else
    find "$p" \
      -type f \
      ! -path '*/__pycache__/*' \
      ! -name '*.pyc'
  fi
done | sort -u > "$file_list"

echo "SCANOSS: scanning $(wc -l < "$file_list" | tr -d ' ') first-party files"

scanoss-py scan \
  --files-from "$file_list" \
  --retry 0 \
  --wfp-output "$work_dir/scanoss-input.wfp" \
  -o "$out" \
  .

echo "SCANOSS raw results -> $out"

scanoss-py results "$out" \
  --match-type file,snippet \
  --format json \
  --output "${out%.json}-matches.json"

scanoss-py inspect raw copyleft \
  -i "$out" \
  --output "${out%.json}-copyleft.json" \
  --status "${out%.json}-copyleft.md"

echo "Matches  -> ${out%.json}-matches.json"
echo "Copyleft -> ${out%.json}-copyleft.json"