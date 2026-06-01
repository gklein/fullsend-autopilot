#!/usr/bin/env bash
set -euo pipefail

# Check for new comments on a GitHub issue or PR since a given timestamp.
#
# Usage: check-comments.sh <issue|pr> <number> <since-iso-timestamp>
#
# Exit codes:
#   0 — new comments found (printed to stdout)
#   1 — no new comments

TYPE="${1:?Usage: check-comments.sh <issue|pr> <number> <since-iso-timestamp>}"
NUMBER="${2:?}"
SINCE="${3:?}"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
if [[ -z "$REPO" ]]; then
  echo "ERROR: Not in a GitHub repo or gh not authenticated" >&2
  exit 1
fi

COMMENTS=$(gh api "repos/${REPO}/issues/${NUMBER}/comments?since=${SINCE}&per_page=100" 2>/dev/null || echo "[]")

if [[ "$TYPE" == "pr" ]]; then
  REVIEW_COMMENTS=$(gh api "repos/${REPO}/pulls/${NUMBER}/comments?since=${SINCE}&per_page=100" 2>/dev/null || echo "[]")
  COMMENTS=$(echo "$COMMENTS" "$REVIEW_COMMENTS" | jq -s 'add | sort_by(.created_at)')
fi

COUNT=$(echo "$COMMENTS" | jq 'length')

if [[ "$COUNT" -gt 0 ]]; then
  echo "$COMMENTS" | jq -r '.[] | "--- Comment by \(.user.login) at \(.created_at) ---\n\(.body)\n"'
  exit 0
fi

exit 1
