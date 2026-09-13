# tools/ort-audit.sh
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

out_dir="${1:-/tmp/epidemica-ort}"
ort_repo_config="$repo_root/tools/ort-repository.yaml"

ORT_IMAGE="${ORT_IMAGE:-ghcr.io/oss-review-toolkit/ort}"

# On Apple Silicon:
# - ORT's Pub/Flutter bootstrap currently works reliably as amd64.
# - Mix/BEAM should run natively as arm64.
ORT_PUB_PLATFORM="${ORT_PUB_PLATFORM:-linux/amd64}"
ORT_MIX_PLATFORM="${ORT_MIX_PLATFORM:-linux/arm64}"
ORT_SCAN_PLATFORM="${ORT_SCAN_PLATFORM:-linux/arm64}"

rm -rf "$out_dir"

mkdir -p \
  "$out_dir/pub/analyzer" \
  "$out_dir/pub/scanner" \
  "$out_dir/mix/analyzer" \
  "$out_dir/mix/scanner"

echo
echo "=== ORT: analyzing Pub dependency graphs ==="

echo
echo "=== ORT: preparing Pub workspace members for independent analysis ==="

pub_temp_overrides=()
pub_temp_lockfiles=()
pub_temp_tooldirs=()

cleanup_pub_analysis_files() {
  for f in "${pub_temp_overrides[@]}"; do
    rm -f "$f"
  done

  for f in "${pub_temp_lockfiles[@]}"; do
    rm -f "$f"
  done

  for d in "${pub_temp_tooldirs[@]}"; do
    rm -rf "$d"
  done
}

trap cleanup_pub_analysis_files EXIT

for pubspec in \
  "$repo_root"/apps/*/pubspec.yaml \
  "$repo_root"/packages/*/pubspec.yaml
do
  [[ -f "$pubspec" ]] || continue

  dir="$(dirname "$pubspec")"
  override="$dir/pubspec_overrides.yaml"
  lockfile="$dir/pubspec.lock"
  tool_dir="$dir/.dart_tool"

  if [[ -e "$override" ]]; then
    echo "ERROR: refusing to overwrite existing $override" >&2
    exit 2
  fi

  # Remember which generated artifacts did not exist before the audit,
  # so cleanup cannot remove a developer's existing files.
  if [[ ! -e "$lockfile" ]]; then
    pub_temp_lockfiles+=("$lockfile")
  fi

  if [[ ! -e "$tool_dir" ]]; then
    pub_temp_tooldirs+=("$tool_dir")
  fi

  printf 'resolution:\n' > "$override"
  pub_temp_overrides+=("$override")

  echo "  independent Pub resolution: ${dir#$repo_root/}"
done

docker run --rm \
  --platform "$ORT_PUB_PLATFORM" \
  -v "$repo_root:/project" \
  -v "$ort_repo_config:/project/.ort.yml:ro" \
  -v "$out_dir:/out" \
  "$ORT_IMAGE" \
  -P ort.analyzer.enabledPackageManagers=Pub \
  -P ort.analyzer.allowDynamicVersions=true \
  -P ort.analyzer.skipExcluded=true \
  analyze \
  -f JSON \
  -i /project \
  -o /out/pub/analyzer

echo
echo "=== ORT: analyzing Mix dependency graph ==="

docker run --rm \
  --platform "$ORT_MIX_PLATFORM" \
  -v "$repo_root:/project" \
  -v "$ort_repo_config:/project/.ort.yml:ro" \
  -v "$out_dir:/out" \
  "$ORT_IMAGE" \
  -P ort.analyzer.enabledPackageManagers=Mix \
  -P ort.analyzer.skipExcluded=true \
  analyze \
  -f JSON \
  -i /project \
  -o /out/mix/analyzer

echo
echo "=== ORT: scanning Pub dependency sources ==="

docker run --rm \
  --platform "$ORT_SCAN_PLATFORM" \
  -v "$repo_root:/project" \
  -v "$out_dir:/out" \
  "$ORT_IMAGE" \
  -P ort.scanner.skipExcluded=true \
  scan \
  -f JSON \
  -i /out/pub/analyzer/analyzer-result.json \
  -o /out/pub/scanner

echo
echo "=== ORT: scanning Mix dependency sources ==="

docker run --rm \
  --platform "$ORT_SCAN_PLATFORM" \
  -v "$repo_root:/project" \
  -v "$out_dir:/out" \
  "$ORT_IMAGE" \
  -P ort.scanner.skipExcluded=true \
  scan \
  -f JSON \
  -i /out/mix/analyzer/analyzer-result.json \
  -o /out/mix/scanner

echo
echo "ORT audit complete."
echo
echo "Pub analyzer:"
echo "  $out_dir/pub/analyzer/analyzer-result.json"
echo "Pub scanner:"
echo "  $out_dir/pub/scanner/scan-result.json"
echo
echo "Mix analyzer:"
echo "  $out_dir/mix/analyzer/analyzer-result.json"
echo "Mix scanner:"
echo "  $out_dir/mix/scanner/scan-result.json"