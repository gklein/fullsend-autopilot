#!/usr/bin/env bash
set -euo pipefail

# Collect all review feedback on a PR: check-run status, review decisions,
# inline review comments, and issue-level comments.
#
# Usage: get-review-feedback.sh <pr-number> [since-iso-timestamp]
#
# Without a timestamp, returns ALL feedback. With a timestamp, returns
# only comments created or updated after that time.
#
# Always exits 0. Output sections may be empty if there is no feedback.

PR_NUMBER="${1:?Usage: get-review-feedback.sh <pr-number> [since-iso-timestamp]}"
SINCE="${2:-}"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
if [[ -z "$REPO" ]]; then
  echo "ERROR: Not in a GitHub repo or gh not authenticated" >&2
  exit 1
fi

# Fetch PR metadata once (headRefOid, reviewDecision, reviews)
PR_DATA=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid,reviewDecision,reviews 2>/dev/null || echo "{}")
HEAD_SHA=$(echo "$PR_DATA" | jq -r '.headRefOid // empty')

# --- Dispatch action status (review / fix jobs) ---
echo "=== ACTION STATUS ==="

if [[ -n "$HEAD_SHA" ]]; then
  ALL_CHECK_RUNS=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs?per_page=100" \
    --jq '[.check_runs[]]' \
    2>/dev/null || echo "[]")

  CHECK_RUNS=$(echo "$ALL_CHECK_RUNS" | jq '[.[] | select(.name | startswith("dispatch /"))]')

  echo "$CHECK_RUNS" | jq -r '.[]
    | "\(.name): \(.status) | conclusion: \(.conclusion // "pending") | \(.started_at) → \(.completed_at // "running")"'

  ACTIVE=$(echo "$CHECK_RUNS" | jq '[.[] | select(.status == "in_progress" or .status == "queued")]')
  FAILED=$(echo "$CHECK_RUNS" | jq '[.[] | select(.conclusion == "failure")]')

  if [[ $(echo "$ACTIVE" | jq 'length') -gt 0 ]]; then
    echo ""
    echo ">>> AGENT STILL RUNNING — review results may be incomplete <<<"
    echo "$ACTIVE" | jq -r '.[] | "  \(.name): \(.status) since \(.started_at)"'
  fi

  if [[ $(echo "$FAILED" | jq 'length') -gt 0 ]]; then
    echo ""
    echo ">>> AGENT JOB FAILED — check workflow logs <<<"
    echo "$FAILED" | jq -r '.[] | "  \(.name): FAILED at \(.completed_at)"'
  fi

  # Only check workflow runs if no dispatch check-runs were found
  DISPATCH_COUNT=$(echo "$CHECK_RUNS" | jq 'length')
  if [[ "$DISPATCH_COUNT" -eq 0 ]]; then
    ME=$(gh api user --jq .login 2>/dev/null || echo "")
    WF_RUNS="[]"
    if [[ -n "$ME" ]]; then
      WF_RUNS=$(gh api "repos/${REPO}/actions/runs?per_page=10&event=issue_comment&actor=${ME}" 2>/dev/null \
        | jq '[.workflow_runs[] | select(.status == "in_progress" or .status == "queued")]' \
        2>/dev/null || echo "[]")
    fi

    if [[ $(echo "$WF_RUNS" | jq 'length') -gt 0 ]]; then
      RUN_ID=$(echo "$WF_RUNS" | jq -r '.[0].id')
      RUN_URL=$(echo "$WF_RUNS" | jq -r '.[0].html_url')

      WF_JOBS=$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" \
        --jq '[.jobs[] | select(.name | startswith("dispatch /")) | select(.status == "in_progress" or .status == "queued")]' \
        2>/dev/null || echo "[]")

      if [[ $(echo "$WF_JOBS" | jq 'length') -gt 0 ]]; then
        echo ""
        echo ">>> WORKFLOW RUN IN PROGRESS: ${RUN_URL} <<<"
        echo "$WF_JOBS" | jq -r '.[] | "  \(.name): \(.status) (started \(.started_at))"'
      fi
    fi
  fi
else
  echo "(unable to determine head SHA)"
fi

echo ""

# --- CI check failures (non-dispatch: test suites, linters, etc.) ---
echo "=== CI CHECK FAILURES ==="

if [[ -n "$HEAD_SHA" ]]; then
  CI_FAILED=$(echo "$ALL_CHECK_RUNS" | jq -r \
    '[.[] | select(.name | startswith("dispatch /") | not) | select(.conclusion == "failure")]
     | .[] | "\(.name): FAILED | \(.output.title // "no details") | \(.html_url // "")"' \
    2>/dev/null || echo "")

  if [[ -n "$CI_FAILED" ]]; then
    echo "$CI_FAILED"
  else
    echo "(no CI check failures)"
  fi
else
  echo "(unable to determine head SHA)"
fi

echo ""

# --- Overall review state (reuse PR_DATA) ---
echo "=== REVIEW STATE ==="
echo "$PR_DATA" | jq -r '"Decision: \(.reviewDecision // "PENDING")\nReviewers:\n" +
  (.reviews // [] | map("  - \(.author.login): \(.state) (\(.submittedAt))") | join("\n"))' \
  2>/dev/null || echo "Decision: UNKNOWN"

echo ""

# --- PR review comments (inline code comments) ---
echo "=== INLINE REVIEW COMMENTS ==="
SINCE_QS=""
if [[ -n "$SINCE" ]]; then
  SINCE_QS="since=${SINCE}&"
fi

gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments?${SINCE_QS}per_page=100" \
  --jq '.[] | "[INLINE] \(.user.login) on \(.path):\(.line // .original_line // "?")\nState: \(.state // "open") | Created: \(.created_at) | Updated: \(.updated_at)\n\(.body)\n---"' \
  2>/dev/null || true

echo ""

# --- Issue-level comments on the PR ---
echo "=== PR COMMENTS ==="
gh api "repos/${REPO}/issues/${PR_NUMBER}/comments?${SINCE_QS}per_page=100" \
  --jq '.[] | "[COMMENT] \(.user.login) at \(.created_at) (updated \(.updated_at))\n\(.body)\n---"' \
  2>/dev/null || true

echo ""

# --- Check if there are any requested changes (reuse PR_DATA reviews) ---
echo "=== CHANGES REQUESTED ==="
echo "$PR_DATA" | jq -r '
  (.reviews // [])
  | [.[] | {author: .author.login, state: .state, body: .body, submitted: .submittedAt}]
  | group_by(.author)
  | map(sort_by(.submitted) | last)
  | .[]
  | select(.state == "CHANGES_REQUESTED")
  | "Reviewer \(.author) requests changes (\(.submitted)):\n\(.body)\n---"' 2>/dev/null || true
