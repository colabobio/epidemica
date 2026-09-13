#!/usr/bin/env bash
# tools/list-ort-dependencies.sh
#
# Summarizes declared / resolved dependency licenses from ORT Analyzer.
#
# License sources:
#   - Mix / Hex and other ecosystems:
#       ORT's declared_licenses_processed.spdx_expression
#
#   - Pub:
#       tools/lookup-pub-licenses.py output, which inspects the exact
#       published package artifact's LICENSE / COPYING files.
#
# This script does NOT scan dependency source code.
#
# Usage:
#
#   bash tools/list-ort-dependencies.sh "$tmp/ort"

set -euo pipefail


# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <ort-output-dir>" >&2
  echo "example: $0 /tmp/epidemica-provenance/ort" >&2
  exit 2
fi

ort_dir="$1"

pub_result="$ort_dir/pub/analyzer/analyzer-result.json"
mix_result="$ort_dir/mix/analyzer/analyzer-result.json"
pub_lookup_file="$ort_dir/pub/pub-license-lookup.json"


# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required" >&2
  exit 2
}

inputs=()

if [[ -f "$pub_result" ]]; then
  inputs+=("$pub_result")
fi

if [[ -f "$mix_result" ]]; then
  inputs+=("$mix_result")
fi

if [[ ${#inputs[@]} -eq 0 ]]; then
  echo "error: no ORT analyzer results found under:" >&2
  echo "  $ort_dir" >&2
  exit 2
fi


# ---------------------------------------------------------------------------
# Pub license enrichment
# ---------------------------------------------------------------------------

# Pub package metadata currently does not populate declared licenses well
# enough for this audit, so lookup-pub-licenses.py inspects LICENSE/COPYING
# files from the exact Pub artifacts resolved by ORT.
#
# Keep the report usable without this file, but all Pub packages lacking
# ORT license metadata will then correctly fall into REVIEW / UNKNOWN.

if [[ -f "$pub_lookup_file" ]]; then
  PUB_LOOKUP="$(cat "$pub_lookup_file")"
else
  PUB_LOOKUP='{}'

  echo "warning: Pub license lookup not found:" >&2
  echo "  $pub_lookup_file" >&2
  echo >&2
  echo "Pub dependencies without ORT-declared licenses will be REVIEW/UNKNOWN." >&2
  echo "Run:" >&2
  echo "  python3 tools/lookup-pub-licenses.py \\" >&2
  echo "    \"$pub_result\" \\" >&2
  echo "    \"$pub_lookup_file\"" >&2
  echo >&2
fi


# ---------------------------------------------------------------------------
# License policy
# ---------------------------------------------------------------------------

# Keep this deliberately conservative.
#
# A dependency is automatically ALLOW only if ORT / the Pub license lookup
# resolves its SPDX expression entirely to licenses explicitly approved here.
#
# Everything else goes to REVIEW.
#
# Extend this list only after making an explicit project policy decision.

ALLOW_LICENSES='[
  "Apache-2.0",
  "MIT",
  "BSD-2-Clause",
  "BSD-3-Clause",
  "ISC"
]'


# ---------------------------------------------------------------------------
# Build normalized dependency table
# ---------------------------------------------------------------------------

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

jq -r \
  --argjson allow "$ALLOW_LICENSES" \
  --argjson pub_lookup "$PUB_LOOKUP" '

#
# Choose the best available license expression.
#
# Priority:
#
#   1. ORT normalized declared license.
#   2. Pub artifact LICENSE/COPYING lookup.
#   3. ORT raw declared license text.
#   4. UNKNOWN.
#
def license_expression:
  if (.declared_licenses_processed.spdx_expression // "") != "" then
    .declared_licenses_processed.spdx_expression

  elif ($pub_lookup[.id].license_expression // "") != "" then
    $pub_lookup[.id].license_expression

  elif ((.declared_licenses // []) | length) > 0 then
    (.declared_licenses | join(" / "))

  else
    "UNKNOWN"
  end;


#
# Record where the license determination came from.
#
def license_source:
  if (.declared_licenses_processed.spdx_expression // "") != "" then
    "ORT"

  elif ($pub_lookup[.id].license_expression // "") != "" then
    "PUB-LICENSE"

  else
    "UNKNOWN"
  end;


#
# Break simple SPDX AND / OR expressions into license identifiers.
#
# This is deliberately not intended to become a complete SPDX parser.
# Complex expressions and exceptions are sent to REVIEW.
#
def license_tokens($expr):
  $expr
  | gsub("\\("; " ")
  | gsub("\\)"; " ")
  | gsub("\\bAND\\b"; " ")
  | gsub("\\bOR\\b"; " ")
  | split(" ")
  | map(select(length > 0));


#
# Apply the conservative project policy.
#
def verdict($expr):
  if $expr == "UNKNOWN" then
    "REVIEW"

  # Copyleft, weak copyleft, source-available / unusual identifiers,
  # unresolved SPDX values, etc. always receive human review.
  elif ($expr | test(
    "(?i)(AGPL|LGPL|GPL|MPL|EPL|CDDL|CPL|OSL|SSPL|LicenseRef|NOASSERTION|NONE)"
  )) then
    "REVIEW"

  # License exceptions can change the effective obligations. Do not try
  # to interpret them with this lightweight policy script.
  elif ($expr | test("\\bWITH\\b")) then
    "REVIEW"

  # Simple AND / OR expressions are automatically allowed only when
  # every license identifier belongs to the explicit allow-list.
  elif all(
    license_tokens($expr)[];
    $allow | index(.) != null
  ) then
    "ALLOW"

  else
    "REVIEW"
  end;


#
# ORT 93.x stores each dependency package directly in packages[].
#
.analyzer.result.packages[]?

| license_expression as $license

| [
    verdict($license),
    (.id // "unknown"),
    $license,
    license_source,
    (.purl // "")
  ]

| @tsv

' ${inputs[@]+"${inputs[@]}"} \
| sort -u > "$tmp"


# ---------------------------------------------------------------------------
# Counts
# ---------------------------------------------------------------------------

allow_count="$(
  awk -F '\t' '
    $1 == "ALLOW" { n++ }
    END { print n + 0 }
  ' "$tmp"
)"

review_count="$(
  awk -F '\t' '
    $1 == "REVIEW" { n++ }
    END { print n + 0 }
  ' "$tmp"
)"

total_count="$(
  wc -l < "$tmp" | tr -d ' '
)"


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

echo
echo "ORT dependency license report"
echo "============================="
echo
echo "Dependencies: $total_count"
echo "ALLOW:        $allow_count"
echo "REVIEW:       $review_count"
echo


if [[ "$review_count" -gt 0 ]]; then
  echo "REVIEW"
  echo "------"

  awk -F '\t' '
    $1 == "REVIEW" {
      printf "%-54s  %-28s  [%s]\n", $2, $3, $4
    }
  ' "$tmp"

  echo
fi


if [[ "$allow_count" -gt 0 ]]; then
  echo "ALLOW"
  echo "-----"

  awk -F '\t' '
    $1 == "ALLOW" {
      printf "%-54s  %-28s  [%s]\n", $2, $3, $4
    }
  ' "$tmp"

  echo
fi


echo "Policy:"
echo "  ALLOW  = declared/resolved SPDX expression consists only of:"
echo "           Apache-2.0, MIT, BSD-2-Clause, BSD-3-Clause, ISC"
echo
echo "  REVIEW = copyleft, weak-copyleft, custom, unknown,"
echo "           exception-bearing, unparsable, or otherwise unapproved"
echo
echo "License sources:"
echo "  [ORT]         package-declared license normalized by ORT Analyzer"
echo "  [PUB-LICENSE] LICENSE/COPYING file from the exact Pub artifact"
echo "  [UNKNOWN]     no usable license determination was available"
echo
echo "Note: this report does not scan dependency source code."