#!/usr/bin/env bash
set -euo pipefail

# Find and watch a fullsend workflow run until it completes.
#
# Usage: wait-for-run.sh <issue|pr> <number> [since-iso-timestamp] [job-name]
#
# Locates the workflow run by matching the current GitHub user (actor) and
# timestamp. If a job-name is provided (e.g. "Code"), verifies the run
# contains a non-skipped job matching "dispatch / Code" before watching.
#
# Fullsend job naming: active jobs are "dispatch / <Name> / <Name>"
# (e.g. "dispatch / Code / Code"), skipped jobs are "dispatch / <Name>".
# The match checks for a non-skipped job starting with "dispatch / <Name>".
#
# If since-timestamp is omitted, defaults to 2 minutes ago (with a warning).
#
# Exit codes:
#   0 — run completed successfully
#   1 — no matching workflow run found after 3 minutes of retries
#   2 — run completed with failure (includes failed job details)

TYPE="${1:?Usage: wait-for-run.sh <issue|pr> <number> [since-iso-timestamp] [command]}"
NUMBER="${2:?Usage: wait-for-run.sh <issue|pr> <number> [since-iso-timestamp] [command]}"

if [[ -z "${3:-}" ]]; then
  echo "WARNING: No timestamp provided, defaulting to 2 minutes ago" >&2
  SINCE=$(date -u -v-2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
else
  SINCE="$3"
fi

COMMAND="${4:-}"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
if [[ -z "$REPO" ]]; then
  echo "ERROR: Not in a GitHub repo or gh not authenticated" >&2
  exit 1
fi

ME=$(gh api user --jq .login 2>/dev/null || echo "")
if [[ -z "$ME" ]]; then
  echo "ERROR: Could not determine current GitHub user" >&2
  exit 1
fi

# Resolve the issue/PR title to disambiguate runs across different issues.
if [[ "$TYPE" == "pr" ]]; then
  TITLE=$(gh pr view "$NUMBER" --repo "$REPO" --json title --jq .title 2>/dev/null || echo "")
else
  TITLE=$(gh issue view "$NUMBER" --repo "$REPO" --json title --jq .title 2>/dev/null || echo "")
fi

# Wait for the workflow run to appear. GitHub webhook delivery + workflow
# queuing can take 30s–3min depending on load.
# Uses actor + timestamp + display_title to find candidate runs.
RUN_ID=""
for _ in $(seq 1 9); do
  CANDIDATES=$(gh api "repos/${REPO}/actions/runs?per_page=30&event=issue_comment&actor=${ME}" 2>/dev/null \
    | jq -r --arg since "$SINCE" --arg title "$TITLE" \
    '[.workflow_runs[] | select(.created_at > $since) | select($title == "" or .display_title == $title)]
     | sort_by(.created_at) | reverse | [.[].id] | .[]' \
    2>/dev/null || echo "")

  if [[ -z "$CANDIDATES" ]]; then
    sleep 20
    continue
  fi

  if [[ -z "$COMMAND" ]]; then
    # No command filter — take the latest candidate
    RUN_ID=$(echo "$CANDIDATES" | head -1)
    break
  fi

  # Verify the candidate contains a non-skipped job matching the command
  for CID in $CANDIDATES; do
    HAS_JOB=$(gh api "repos/${REPO}/actions/runs/${CID}/jobs" \
      --jq "[.jobs[] | select(.name | startswith(\"dispatch / ${COMMAND}\")) | select(.conclusion != \"skipped\")] | length" \
      2>/dev/null || echo "0")

    if [[ "$HAS_JOB" -gt 0 ]]; then
      RUN_ID="$CID"
      break 2
    fi
  done

  sleep 20
done

if [[ -z "$RUN_ID" ]]; then
  if [[ -n "$COMMAND" ]]; then
    echo "No workflow run with job 'dispatch / ${COMMAND}' found for ${TYPE} #${NUMBER} (actor: ${ME}, since: ${SINCE}) after 3 minutes" >&2
  else
    echo "No workflow run found for ${TYPE} #${NUMBER} (actor: ${ME}, since: ${SINCE}) after 3 minutes" >&2
  fi
  exit 1
fi

RUN_URL="https://github.com/${REPO}/actions/runs/${RUN_ID}"
echo "Watching run ${RUN_ID}: ${RUN_URL}"

if gh run watch "$RUN_ID" --repo "$REPO" --exit-status 2>&1; then
  echo ""
  echo "RUN_COMPLETED: success"

  gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" \
    --jq '.jobs[]
      | select(.name | startswith("dispatch /"))
      | select(.conclusion != "skipped")
      | "  \(.name): \(.conclusion) (\(.started_at) → \(.completed_at))"' \
    2>/dev/null || true

  exit 0
else
  echo ""
  echo "RUN_COMPLETED: failure"

  gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" \
    --jq '.jobs[]
      | select(.conclusion == "failure")
      | "  FAILED: \(.name) — \(.html_url)"' \
    2>/dev/null || true

  exit 2
fi
