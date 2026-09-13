#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <scanoss-report.json> [purl-regex]" >&2
  exit 2
fi

report="$1"
filter="${2:-}"

if [[ ! -f "$report" ]]; then
  echo "error: report not found: $report" >&2
  exit 2
fi

jq -r --arg filter "$filter" '
def arr:
  if . == null then []
  elif type == "array" then .
  else [.] end;

to_entries[]
| select(.value | type == "array")
| .key as $local
| .value[]
| select(type == "object")
| select(.id == "snippet" or .id == "file")
| (.purl | arr) as $purls

| select(
    ($filter == "")
    or any($purls[];
      tostring | test($filter; "i")
    )
  )

| "LOCAL FILE:     \($local)
MATCH TYPE:     \(.id)
LOCAL LINES:    \(.lines // "unknown")
MATCHED:        \(.matched // "unknown")
COMPONENT:      \(.component // "unknown")
VERSION:        \(.version // "unknown")
UPSTREAM:       \(.url // "unknown")
UPSTREAM FILE:  \(.file // "unknown")
UPSTREAM LINES: \(.oss_lines // "unknown")
PURL:           \(($purls | map(tostring)) | join(", "))
LICENSE:        \((.licenses | arr |
                    map(
                      if type == "object"
                      then (.spdxid // .name // "unknown")
                      else tostring
                      end
                    )
                  ) | join(", "))
---"
' "$report"