#!/usr/bin/env bash
# tools/provenance-audit.sh
#
# Complete release provenance / dependency-license audit:
#
#   1. ScanCode
#      First-party source: embedded license / copyright detection.
#
#   2. SCANOSS
#      First-party source: OSS file / snippet similarity.
#
#   3. ORT
#      Third-party dependency graph + declared / published licenses.
#
# All stages run even if an earlier policy check reports a finding.
# The script exits non-zero at the end if a blocking check failed.

set -uo pipefail

tmp="${TMPDIR:-/tmp}/epidemica-provenance"
mkdir -p "$tmp"

audit_failed=0

generate_report() {
  echo
  echo "=== Generating Markdown report ==="

  python3 tools/generate-provenance-report.py \
    "$tmp" \
    "$tmp/provenance-report.md" || true

  echo "Report:"
  echo "  $tmp/provenance-report.md"
}

trap generate_report EXIT

# ---------------------------------------------------------------------------
# 1. ScanCode
# ---------------------------------------------------------------------------

echo
echo "=== 1/3 ScanCode: embedded license/copyright detection ==="
echo

if bash tools/license-scan.sh "$tmp/scancode.json"; then
  if ! python3 tools/check-license-scan.py "$tmp/scancode.json"; then
    audit_failed=1
  fi
else
  echo "ERROR: ScanCode scan failed." >&2
  audit_failed=1
fi


# ---------------------------------------------------------------------------
# 2. SCANOSS
# ---------------------------------------------------------------------------

echo
echo "=== 2/3 SCANOSS: source provenance / snippet detection ==="
echo

if bash tools/scanoss-scan.sh "$tmp/scanoss.json"; then

  # Run the policy check, but do not stop before printing match details.
  if ! python3 tools/check-scanoss.py "$tmp/scanoss-copyleft.json"; then
    audit_failed=1
  fi

  echo
  echo "--- SCANOSS match details ---"
  echo

  bash tools/list-scanoss-matches.sh "$tmp/scanoss.json" || {
    echo "ERROR: could not list SCANOSS matches." >&2
    audit_failed=1
  }

else
  echo "ERROR: SCANOSS scan failed." >&2
  audit_failed=1
fi


# ---------------------------------------------------------------------------
# 3. ORT dependency / license audit
# ---------------------------------------------------------------------------

echo
echo "=== 3/3 ORT: dependency graph / license audit ==="
echo

if bash tools/ort-dependency-audit.sh "$tmp/ort"; then

  pub_analyzer="$tmp/ort/pub/analyzer/analyzer-result.json"
  pub_lookup="$tmp/ort/pub/pub-license-lookup.json"

  echo
  echo "--- Resolving Pub package licenses ---"
  echo

  if ! python3 tools/lookup-pub-licenses.py \
    "$pub_analyzer" \
    "$pub_lookup"
  then
    echo "ERROR: Pub license lookup failed." >&2
    audit_failed=1
  fi

  echo
  echo "--- Dependency license report ---"
  echo

  if ! bash tools/list-ort-dependencies.sh "$tmp/ort"; then
    echo "ERROR: dependency license report failed." >&2
    audit_failed=1
  fi

else
  echo "ERROR: ORT dependency analysis failed." >&2
  audit_failed=1
fi


# ---------------------------------------------------------------------------
# Final status
# ---------------------------------------------------------------------------

echo
echo "============================================================"
echo

if [[ "$audit_failed" -eq 0 ]]; then
  echo "Automated provenance audit completed successfully."
else
  echo "Automated provenance audit completed with findings/errors."
fi

echo "Review artifacts under:"
echo "  $tmp"
echo

exit "$audit_failed"