#!/usr/bin/env bash
# tools/ort-dependency-audit.sh
#
# Resolves Epidemica's third-party dependency graphs with ORT.
#
# This script intentionally runs only ORT Analyzer:
#   - Pub / Flutter dependencies
#   - Mix / Hex dependencies
#
# It does NOT download and ScanCode dependency source.
# Use list-ort-dependencies.sh afterwards to review declared licenses.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

out_dir="${1:-/tmp/epidemica-ort}"
ort_repo_config="$repo_root/tools/ort-repository.yaml"

ORT_IMAGE="${ORT_IMAGE:-ghcr.io/oss-review-toolkit/ort}"

# Apple Silicon:
#
# Pub:
# ORT's Flutter bootstrap currently works reliably through linux/amd64.
#
# Mix:
# BEAM / mix_sbom should run natively on arm64; running it through
# amd64 emulation caused Rosetta / BSS errors during testing.
ORT_PUB_PLATFORM="${ORT_PUB_PLATFORM:-linux/amd64}"
ORT_MIX_PLATFORM="${ORT_MIX_PLATFORM:-linux/arm64}"


# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

if [[ ! -f "$ort_repo_config" ]]; then
  echo "ERROR: ORT repository configuration not found:" >&2
  echo "  $ort_repo_config" >&2
  exit 2
fi

command -v docker >/dev/null 2>&1 || {
  echo "ERROR: docker is required." >&2
  exit 2
}


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

rm -rf "$out_dir"

mkdir -p \
  "$out_dir/pub/analyzer" \
  "$out_dir/mix/analyzer"


# ---------------------------------------------------------------------------
# Pub
# ---------------------------------------------------------------------------

echo
echo "=== ORT: preparing Pub workspace members for independent analysis ==="
echo

# ORT's Pub analyzer currently expects a pubspec.lock next to each
# pubspec.yaml it analyzes.
#
# Epidemica uses a Pub workspace, where members normally share the root
# pubspec.lock instead. For the duration of this audit, temporarily:
#
#   1. Disable the root workspace.
#   2. Opt each nested package out of workspace resolution.
#   3. Allow flutter pub get to generate the local lockfiles ORT expects.
#
# All files created by this workaround are removed after Pub analysis.

pub_temp_overrides=()
pub_temp_lockfiles=()
pub_temp_tooldirs=()

root_override="$repo_root/pubspec_overrides.yaml"

cleanup_pub_analysis_files() {
  # The ${array[@]+"${array[@]}"} form is intentional: it works safely with
  # set -u and Apple's older Bash when an array is empty.

  for f in ${pub_temp_overrides[@]+"${pub_temp_overrides[@]}"}; do
    rm -f "$f"
  done

  for f in ${pub_temp_lockfiles[@]+"${pub_temp_lockfiles[@]}"}; do
    rm -f "$f"
  done

  for d in ${pub_temp_tooldirs[@]+"${pub_temp_tooldirs[@]}"}; do
    rm -rf "$d"
  done
}

# Ensure an interrupted run does not leave audit-generated Pub files behind.
trap cleanup_pub_analysis_files EXIT


# Temporarily disable the root workspace.
if [[ -e "$root_override" ]]; then
  echo "ERROR: refusing to overwrite existing file:" >&2
  echo "  $root_override" >&2
  exit 2
fi

printf 'workspace: []\n' > "$root_override"
pub_temp_overrides+=("$root_override")


# Put every Pub package under apps/ and packages/ into independent-resolution
# mode. This includes nested example projects, which may themselves contain
# `resolution: workspace`.
while IFS= read -r -d '' pubspec; do
  dir="$(dirname "$pubspec")"

  override="$dir/pubspec_overrides.yaml"
  lockfile="$dir/pubspec.lock"
  tool_dir="$dir/.dart_tool"

  if [[ -e "$override" ]]; then
    echo "ERROR: refusing to overwrite existing file:" >&2
    echo "  $override" >&2
    exit 2
  fi

  # Only remove files/directories later if they did not exist before the
  # audit. Never delete a developer's existing lockfile or .dart_tool state.
  if [[ ! -e "$lockfile" ]]; then
    pub_temp_lockfiles+=("$lockfile")
  fi

  if [[ ! -e "$tool_dir" ]]; then
    pub_temp_tooldirs+=("$tool_dir")
  fi

  printf 'resolution:\n' > "$override"
  pub_temp_overrides+=("$override")

  echo "  independent Pub resolution: ${dir#$repo_root/}"

done < <(
  find "$repo_root/apps" "$repo_root/packages" \
    -name pubspec.yaml \
    -type f \
    -print0
)


echo
echo "=== ORT: analyzing Pub dependency graphs ==="
echo

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


# Pub resolution is complete. Restore the repository before running Mix.
cleanup_pub_analysis_files
trap - EXIT


# ---------------------------------------------------------------------------
# Mix
# ---------------------------------------------------------------------------

echo
echo "=== ORT: analyzing Mix dependency graph ==="
echo

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


# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

echo
echo "ORT dependency analysis complete."
echo
echo "Pub analyzer:"
echo "  $out_dir/pub/analyzer/analyzer-result.json"
echo
echo "Mix analyzer:"
echo "  $out_dir/mix/analyzer/analyzer-result.json"
echo
echo "Next:"
echo "  bash tools/list-ort-dependencies.sh \"$out_dir\""