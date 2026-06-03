#!/usr/bin/env bash
set -euo pipefail

# Poll for routing labels on an issue or PR until one appears.
#
# Usage: wait-for-label.sh <issue|pr> <number> [label-pattern] [max-retries]
#
# Checks every 60 seconds for labels matching the grep -iE pattern.
# Default pattern covers all fullsend routing labels.
#
# Exit codes:
#   0 — matching label(s) found (all labels printed to stdout)
#   1 — max retries exhausted with no matching labels

TYPE="${1:?Usage: wait-for-label.sh <issue|pr> <number> [label-pattern] [max-retries]}"
NUMBER="${2:?Usage: wait-for-label.sh <issue|pr> <number> [label-pattern] [max-retries]}"
PATTERN="${3:-ready-to-code|triaged|needs-info|duplicate|blocked|ready-for-merge|requires-manual-review|rejected|needs-human|fullsend-no-fix|changes-requested|approved}"
MAX_RETRIES="${4:-20}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for i in $(seq 1 "$MAX_RETRIES"); do
  LABELS=$("$SCRIPT_DIR/check-labels.sh" "$TYPE" "$NUMBER" 2>/dev/null || echo "")

  if echo "$LABELS" | grep -qiE "$PATTERN"; then
    echo "$LABELS"
    exit 0
  fi

  if [[ "$i" -lt "$MAX_RETRIES" ]]; then
    echo "Poll ${i}/${MAX_RETRIES}: no routing labels yet, waiting 60s..." >&2
    sleep 60
  fi
done

echo "No matching labels found after ${MAX_RETRIES} retries (~${MAX_RETRIES} minutes)" >&2
exit 1
