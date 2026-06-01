#!/usr/bin/env bash
set -euo pipefail

# Find an open PR linked to a GitHub issue via timeline cross-references.
# Prefers bot-authored PRs (created by the fullsend code agent) over human PRs.
#
# Usage: find-pr-for-issue.sh <issue-number>
#
# Exits 0 and prints the PR number, title, and URL if found.
# Exits 1 silently if no linked PR exists yet.

ISSUE_NUMBER="${1:?Usage: find-pr-for-issue.sh <issue-number>}"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
if [[ -z "$REPO" ]]; then
  echo "ERROR: Not in a GitHub repo or gh not authenticated" >&2
  exit 1
fi

pick_best_pr() {
  echo "$1" | jq -r '
    sort_by(.author | endswith("[bot]") | not)
    | .[0]
    | "PR #\(.number): \(.title)\n\(.url)"'
}

# Check the issue timeline for cross-referenced PRs (first 100 events)
LINKED=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/timeline?per_page=100" --jq '
  [.[]
   | select(.event == "cross-referenced")
   | select(.source.issue.pull_request != null)
   | select(.source.issue.state == "open")
   | {number: .source.issue.number,
      title:  .source.issue.title,
      url:    .source.issue.html_url,
      author: .source.issue.user.login}]
  | unique_by(.number)' 2>/dev/null || echo "[]")

if [[ $(echo "$LINKED" | jq 'length') -gt 0 ]]; then
  pick_best_pr "$LINKED"
  exit 0
fi

# Fallback: search for PRs whose body mentions the issue number
SEARCH=$(gh pr list --repo "$REPO" --state open --json number,title,url,body,author \
  --jq "[.[] | select(.body | test(\"#${ISSUE_NUMBER}\\\\b\")) | {number, title, url, author: .author.login}] | unique_by(.number)" \
  2>/dev/null || echo "[]")

if [[ $(echo "$SEARCH" | jq 'length') -eq 0 ]]; then
  exit 1
fi

pick_best_pr "$SEARCH"
