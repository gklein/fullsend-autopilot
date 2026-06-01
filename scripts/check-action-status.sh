#!/usr/bin/env bash
set -euo pipefail

# Check whether a fullsend dispatch action is running or has failed.
#
# Usage: check-action-status.sh <issue|pr> <number> <since-iso-timestamp>
#
# For PRs, checks commit check-runs first (fastest), then falls back to
# workflow runs by actor + timestamp.
#
# Exit codes:
#   0 — a dispatch action is still running (details printed to stdout)
#   1 — nothing happening (no running or failed actions found)
#   2 — a dispatch action failed (details printed to stdout)

TYPE="${1:?Usage: check-action-status.sh <issue|pr> <number> <since-iso-timestamp>}"
NUMBER="${2:?}"
SINCE="${3:?}"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
if [[ -z "$REPO" ]]; then
  echo "ERROR: Not in a GitHub repo or gh not authenticated" >&2
  exit 1
fi

# ── For PRs, check commit check-runs first (most direct) ─────────────

if [[ "$TYPE" == "pr" ]]; then
  HEAD_SHA=$(gh pr view "$NUMBER" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null || echo "")

  if [[ -n "$HEAD_SHA" ]]; then
    CHECK_RUNS=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-runs?per_page=100" \
      --jq '[.check_runs[] | select(.name | startswith("dispatch /")) | {name, status, conclusion, started_at, completed_at}]' \
      2>/dev/null || echo "[]")

    RUNNING=$(echo "$CHECK_RUNS" | jq '[.[] | select(.status == "in_progress" or .status == "queued")]')
    if [[ $(echo "$RUNNING" | jq 'length') -gt 0 ]]; then
      echo "ACTION_RUNNING"
      echo "$RUNNING" | jq -r '.[] | "  \(.name): \(.status) (started \(.started_at))"'
      exit 0
    fi

    FAILED=$(echo "$CHECK_RUNS" | jq --arg since "$SINCE" \
      '[.[] | select(.conclusion == "failure") | select(.completed_at > $since)]')
    if [[ $(echo "$FAILED" | jq 'length') -gt 0 ]]; then
      echo "ACTION_FAILED"
      echo "$FAILED" | jq -r '.[] | "  \(.name): FAILED (completed \(.completed_at))"'
      exit 2
    fi
  fi
fi

# ── Fall back to workflow runs by actor + timestamp ───────────────────

ME=$(gh api user --jq .login 2>/dev/null || echo "")
if [[ -z "$ME" ]]; then
  exit 1
fi

ALL_RUNS=$(gh api "repos/${REPO}/actions/runs?per_page=10&event=issue_comment&actor=${ME}" 2>/dev/null \
  | jq --arg since "$SINCE" \
  '[.workflow_runs[] | select(.created_at > $since)]
   | sort_by(.created_at) | reverse' \
  2>/dev/null || echo "[]")

# ── Running or queued ──

RUNNING_RUNS=$(echo "$ALL_RUNS" | jq '[.[] | select(.status == "in_progress" or .status == "queued")]')

if [[ $(echo "$RUNNING_RUNS" | jq 'length') -gt 0 ]]; then
  RUN_ID=$(echo "$RUNNING_RUNS" | jq -r '.[0].id')
  RUN_URL=$(echo "$RUNNING_RUNS" | jq -r '.[0].html_url')

  JOBS=$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" \
    --jq '[.jobs[] | select(.name | startswith("dispatch /")) | {name, status, conclusion, started_at, completed_at}]' \
    2>/dev/null || echo "[]")

  ACTIVE_JOBS=$(echo "$JOBS" | jq '[.[] | select(.status == "in_progress" or .status == "queued")]')

  echo "ACTION_RUNNING"
  echo "  Run: ${RUN_URL}"
  if [[ $(echo "$ACTIVE_JOBS" | jq 'length') -gt 0 ]]; then
    echo "$ACTIVE_JOBS" | jq -r '.[] | "  \(.name): \(.status) (started \(.started_at))"'
  else
    echo "  Workflow in progress — waiting for agent job to start"
  fi
  exit 0
fi

# ── Failed ──

FAILED_RUNS=$(echo "$ALL_RUNS" | jq '[.[] | select(.conclusion == "failure")]')

if [[ $(echo "$FAILED_RUNS" | jq 'length') -gt 0 ]]; then
  RUN_ID=$(echo "$FAILED_RUNS" | jq -r '.[0].id')
  RUN_URL=$(echo "$FAILED_RUNS" | jq -r '.[0].html_url')

  FAILED_JOBS=$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" \
    --jq '[.jobs[] | select(.name | startswith("dispatch /")) | select(.conclusion == "failure") | {name, conclusion, completed_at}]' \
    2>/dev/null || echo "[]")

  echo "ACTION_FAILED"
  echo "  Run: ${RUN_URL}"
  if [[ $(echo "$FAILED_JOBS" | jq 'length') -gt 0 ]]; then
    echo "$FAILED_JOBS" | jq -r '.[] | "  \(.name): FAILED (completed \(.completed_at))"'
  else
    echo "  Workflow failed (no individual dispatch job failure — check run logs)"
  fi
  exit 2
fi

exit 1
