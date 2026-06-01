#!/usr/bin/env bash
set -euo pipefail

# Fetch labels for a GitHub issue or PR, one per line.
#
# Usage: check-labels.sh <issue|pr> <number>
#
# Exits 0 and prints labels (one per line).
# Exits 1 if the issue/PR doesn't exist or gh fails.

TYPE="${1:?Usage: check-labels.sh <issue|pr> <number>}"
NUMBER="${2:?}"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
if [[ -z "$REPO" ]]; then
  echo "ERROR: Not in a GitHub repo or gh not authenticated" >&2
  exit 1
fi

if [[ "$TYPE" == "pr" ]]; then
  LABELS=$(gh pr view "$NUMBER" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
else
  LABELS=$(gh issue view "$NUMBER" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
fi

if [[ -z "$LABELS" ]]; then
  echo "No labels found on ${TYPE} #${NUMBER}"
else
  echo "$LABELS"
fi
