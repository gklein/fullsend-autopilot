---
name: fullsend-autopilot
description: >
  Orchestrates the complete fullsend pipeline — scans the codebase, creates
  or locates a GitHub issue, then drives triage, prioritize, code, review/fix,
  merge, and retro to completion unattended. Invoked when a user wants to go
  from an idea or issue reference to a merged PR with zero manual steps.
allowed-tools: >
  Bash(gh issue *)
  Bash(gh pr *)
  Bash(gh api *)
  Bash(gh search *)
  Bash(gh repo view *)
  Bash(gh run *)
  Bash(bash ${CLAUDE_SKILL_DIR}/scripts/*)
  Bash(grep *)
  Bash(find *)
  Bash(git *)
  Bash(make *)
  Bash(go test *)
  Bash(pytest *)
  Bash(npm test *)
  Read
---

# Fullsend Autopilot

**Input:** `$ARGUMENTS` — free-text description, GitHub issue URL, or `#NNN`.

## Progress

Print this checklist at the start. Update after each phase:

```
- [ ] Phase 0 — Sync
- [ ] Phase 1 — Issue
- [ ] Phase 2 — Triage
- [ ] Phase 3 — Prioritize
- [ ] Phase 4 — Code
- [ ] Phase 5 — Review/Fix
- [ ] Phase 6 — Merge
- [ ] Phase 7 — Retro
```

Report after each phase: `[autopilot] Phase N/7 — <Name> — <outcome>`

---

## Data Sanitization

**All text posted to GitHub** (issue bodies, comments, commit messages) must
be free of local environment data. Never include:

- Absolute local file paths (`/Users/…`, `/home/…`, `/var/folders/…`)
- Local hostnames, FQDNs, or IP addresses
- Environment variable values (tokens, passwords, API keys, secrets)
- Local OS usernames or personal identifiers
- Database connection strings with credentials
- Auth headers (`Bearer …`, `Basic …`)

**Rules:**

1. Use **repo-relative paths** when referencing files — write `src/main.go:42`,
   not `/Users/alice/project/src/main.go:42`.
2. When including test output or error messages in a GitHub comment, strip
   absolute paths and replace with repo-relative equivalents.
3. Never quote raw environment variable values. If an env var is relevant,
   name it (`$DATABASE_URL is unset`) without printing the value.
4. **Pipe every GitHub-bound body** through the sanitizer as a safety net:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/sanitize.sh <<'EOF'
<body text>
EOF
```

The sanitizer masks home-directory paths, hostnames, IPs, known token
patterns (GitHub, AWS, GCP, Slack, OpenAI, JWTs), secret-like env-var
assignments, database connection strings, and HTTP auth headers.

---

## Phase 0 — Sync to latest code

1. Determine the default branch:
   ```bash
   DEFAULT_BRANCH=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|origin/||')
   ```
   Fall back to `main` if that fails.

2. Fetch and check out latest:
   ```bash
   git fetch origin
   git checkout "$DEFAULT_BRANCH"
   git pull origin "$DEFAULT_BRANCH"
   ```

3. If an existing issue is provided, check for a feature branch:
   ```bash
   git branch -r --list "origin/agent/<ISSUE_NUMBER>-*"
   ```
   If found, check it out instead and pull latest.

---

## Phase 1 — Create or locate the issue

### 1.1 Detect input type

Parse `$ARGUMENTS`: GitHub issue URL or `#NNN` → skip to Phase 2.
Free-text description → continue to 1.2.

### 1.2 Scan the codebase for context

Search for files, functions, types, tests, and docs relevant to the
description. Read the primary files involved. The issue quality depends
on this scan.

### 1.3 Search for duplicate issues

```bash
gh issue list --state all --search "<key terms>" --json number,title,state \
  --jq '.[] | "#\(.number) [\(.state)] \(.title)"'
```

Try at least 2 different search queries using different terms from the
description. If duplicates found, print them and ask the user whether
to proceed, reference them, or stop.

### 1.4 Draft the issue

**Title:** Concise, imperative mood ("Add …", "Fix …"). Prefix with
component if the repo uses that convention.

**Body:**

```markdown
## Problem

<Bug or missing capability. Reference files, functions, line numbers.
Include error messages if applicable.>

## Relevant Code

<Key files and symbols with one-line role descriptions.>

## Suggested Implementation

<Step-by-step: which files to modify, functions to change, tests to write.
Reference existing patterns.>

## Context

<Why this matters. Who is affected. Related issues or docs.>

## Tests to Add

<Specific tests to write: positive, negative, and edge cases.
Use the repo's existing test framework and naming conventions.
For each: test name, file, and what it asserts.>

## How to Verify

<Commands to run and observable behavior that confirms "done".>
```

### 1.5 Create the issue

Sanitize the body before posting — use repo-relative paths, no secrets:

```bash
gh issue create --title "<title>" --body "$(bash ${CLAUDE_SKILL_DIR}/scripts/sanitize.sh <<'ISSUE_EOF'
<body>
ISSUE_EOF
)"
```

---

## Phase 2 — Triage

### 2.1 Post the triage command

```bash
BEFORE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh issue comment <ISSUE_NUMBER> --body "/fs-triage"
```

### 2.2 Wait for the triage workflow

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/wait-for-run.sh issue <ISSUE_NUMBER> "$BEFORE_TS" Triage
```

Run with **timeout 600000**. Handle exit codes:
- **0** — success. Proceed to 2.3.
- **1** — no run found. Fall back to polling (see Appendix).
- **2** — run failed. Report failure with URL and stop.

### 2.3 Fetch triage results

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/check-comments.sh issue <ISSUE_NUMBER> "$BEFORE_TS"
```

### 2.4 Check triage outcome labels

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/check-labels.sh issue <ISSUE_NUMBER>
```

Route based on labels:

| Label | Route |
|-------|-------|
| `needs-info` | AI answers from code. Pull latest, scan for answers, **sanitize** and post comment. Wait for re-triage. If still `needs-info`, **STOP**. |
| `duplicate` | **STOP.** Report the original issue. |
| `blocked` | **STOP.** Report the blocker. |
| `ready-to-code` / `triaged` | Proceed to Phase 3. |
| None of the above | **STOP.** Print labels. |

When posting a `needs-info` answer, pipe through the sanitizer:

```bash
gh issue comment <ISSUE_NUMBER> --body "$(bash ${CLAUDE_SKILL_DIR}/scripts/sanitize.sh <<'INFO_EOF'
<answer using repo-relative paths, no secrets or local env data>
INFO_EOF
)"
```

---

## Phase 3 — Prioritize

### 3.1 Post the prioritize command

```bash
BEFORE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh issue comment <ISSUE_NUMBER> --body "/fs-prioritize"
```

### 3.2 Wait for the prioritize workflow

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/wait-for-run.sh issue <ISSUE_NUMBER> "$BEFORE_TS" Prioritize
```

Run with **timeout 600000**. Handle exit codes same as Phase 2.

### 3.3 Fetch and display prioritization results

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/check-comments.sh issue <ISSUE_NUMBER> "$BEFORE_TS"
```

Proceed to Phase 4.

---

## Phase 4 — Code

### 4.0 Pre-check blocking labels

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/check-labels.sh issue <ISSUE_NUMBER>
```

- If `blocked` → **STOP.** Report the blocker.
- If `pr-open` → **STOP.** Report "Human PR already exists for this issue."

### 4.1 Post the code command

```bash
BEFORE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh issue comment <ISSUE_NUMBER> --body "/fs-code"
```

### 4.2 Wait for the code agent

The code agent may run for several minutes. Use **`run_in_background: true`**:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/wait-for-run.sh issue <ISSUE_NUMBER> "$BEFORE_TS" Code
```

Handle exit codes same as Phase 2.

### 4.3 Find the PR

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/find-pr-for-issue.sh <ISSUE_NUMBER>
```

If exit 1 (PR not found yet), wait 30 seconds and retry — GitHub's
cross-reference indexing can lag behind.

Check if this is a fork PR (immutable — check once here):

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
IS_FORK=$(gh api "repos/${REPO}/pulls/<PR_NUMBER>" \
  --jq 'if .head.repo.full_name != .base.repo.full_name then "FORK" else "SAME" end')
```

Note the result. If `FORK`, the fix agent will be blocked in Phase 5.

### 4.4 Local test run

Check out the PR branch and run all discoverable tests locally:

```bash
gh pr checkout <PR_NUMBER>
```

Detect the test framework and run tests:
- Go: `go test ./...` or `make test` / `make go-test`
- Python: `pytest` or `python -m pytest`
- Node: `npm test`
- Make: `make test` if a Makefile with a `test` target exists

Capture any test failures — test name, file, error output. **Sanitize
all test output** (strip absolute paths, replace with repo-relative).
If failures are found, they will be included as additional context in
the first `/fs-fix` comment in Phase 5.

---

## Phase 5 — Review and fix loop

This loop continues until the PR is approved with no outstanding
feedback, or 10 fix rounds are exhausted.

Initialize: `FIX_ROUND=0`

### 5.1 Wait for review checks

```bash
gh pr checks <PR_NUMBER> --watch --fail-fast
```

Run with **timeout 600000**. If timeout, fall back to polling
(see Appendix).

### 5.2 Collect review feedback

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/get-review-feedback.sh <PR_NUMBER>
```

Check the `ACTION STATUS` section first:
- If **"AGENT STILL RUNNING"** — sleep 60, retry step 5.1.
- If **"AGENT JOB FAILED"** — report failure with URL and stop.

### 5.3 Check review outcome labels

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/check-labels.sh pr <PR_NUMBER>
```

| Label | Route |
|-------|-------|
| `ready-for-merge` | Check for open items first. If none, Phase 6. If items remain, proceed to 5.4. |
| `requires-manual-review` | AI attempts to address. If still flagged after fix, **STOP**. |
| `rejected` | **STOP.** |
| `needs-human` | **STOP.** |
| `fullsend-no-fix` | **STOP.** |
| None of the above | Changes requested → proceed to 5.4. |

### 5.4 Filter to new feedback only

Build a list of **new-only** items: unaddressed inline comments, updated
comments, regressions, and local test failures. Exclude items already
fixed that have not regressed.

### 5.5 Check for fork PR

If the fork check from step 4.3 returned `FORK`, **STOP** and report:
"Fork PR — fix agent blocked for security. Manual fixes required."

### 5.6 Post /fs-fix with content

Increment: `FIX_ROUND=$((FIX_ROUND + 1))`

**Sanitize before posting** — use repo-relative paths in file references,
strip absolute paths and secrets from any quoted test output:

```bash
REVIEW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh pr comment <PR_NUMBER> --body "$(bash ${CLAUDE_SKILL_DIR}/scripts/sanitize.sh <<'FIX_EOF'
/fs-fix

## Review feedback to address

<For each new review item:
- File and line (repo-relative, if inline comment)
- Reviewer's comment (quoted)
- What needs to change>

## Local test failures

<For each local test failure (if any):
- Test name and file (repo-relative)
- Error output (sanitized — no absolute paths or env values)
- What likely needs to change>

FIX_EOF
)"
```

### 5.7 Wait for fix, then review

**Important:** Pass the literal timestamp value from 5.6, not a variable:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/wait-for-run.sh pr <PR_NUMBER> "<REVIEW_TS_VALUE>" Fix
```

After the fix agent finishes, wait for review checks:

```bash
gh pr checks <PR_NUMBER> --watch --fail-fast
```

### 5.8 Re-run local tests

```bash
git checkout <PR_BRANCH> && git pull origin <PR_BRANCH>
```

Run the same test suite as step 4.4. If tests fail and the fix is
trivial (e.g. a test assertion matching a panel border), fix and push
locally, then **wait for the review workflow to re-run**:

```bash
gh pr checks <PR_NUMBER> --watch --fail-fast
```

Poll `reviewDecision` until it returns a value (sleep 30, max 20
retries). The review bot must evaluate the latest commit before the
loop can check approval status.

### 5.9 Loop back to 5.2

Continue until APPROVED with no open items and tests pass, or 10 fix
rounds exhausted → **STOP**.

---

## Phase 6 — Merge

### 6.1 Wait for checks and verify approval

First, wait for all PR checks (including the review workflow) to finish:

```bash
gh pr checks <PR_NUMBER> --watch --fail-fast
```

Run with **timeout 600000**. If no checks are configured, proceed.

Then poll for the review decision — the review bot may take time to
post its verdict after checks pass:

```bash
gh pr view <PR_NUMBER> --json reviewDecision --jq .reviewDecision
```

If the result is empty or not `APPROVED`, sleep 30 seconds and retry.
Max 20 retries (~10 minutes). If still not `APPROVED` after retries,
go back to Phase 5.

### 6.2 Check for merge conflicts

```bash
gh pr view <PR_NUMBER> --json mergeable --jq .mergeable
```

If `CONFLICTING`, checkout the PR branch, merge `origin/<DEFAULT_BRANCH>`,
resolve conflicts, commit, push, and wait for CI:

```bash
git fetch origin
gh pr checkout <PR_NUMBER>
git merge origin/<DEFAULT_BRANCH>
# resolve conflicts
git add <resolved-files>
git commit -m "merge: resolve conflicts with <DEFAULT_BRANCH>"
git push
gh pr checks <PR_NUMBER> --watch --fail-fast
```

### 6.3 Merge the PR

Merge directly. If merge queue required, retry with `--merge-queue`:

```bash
gh pr merge <PR_NUMBER> --squash --delete-branch
```

```bash
gh pr merge <PR_NUMBER> --merge-queue
```

---

## Phase 7 — Cleanup and retrospective

1. Close the issue if still open:
   ```bash
   STATE=$(gh issue view <ISSUE_NUMBER> --json state --jq .state)
   gh issue close <ISSUE_NUMBER>  # only if still open
   ```

2. Post `/fs-retro` on both the issue and PR (do not wait):
   ```bash
   gh issue comment <ISSUE_NUMBER> --body "/fs-retro"
   gh pr comment <PR_NUMBER> --body "/fs-retro"
   ```

3. Print pipeline summary:

```
[autopilot] ═══ Pipeline Complete ═══

Issue:    #<NUMBER> — <title> — <url>
PR:       #<NUMBER> — <title> — <url>
Triage:   <outcome label>
RICE:     <score or "not scored">
Code:     PR created by <author>
Review:   <disposition>
Fix:      <N> round(s)
Merge:    <direct merge | merge queue>
Retro:    commands sent (results pending)
```

---

## Appendix — Fallback polling

If `wait-for-run.sh` exits 1 (no run found) or the Bash tool times out,
fall back to manual polling with `check-comments.sh` and
`check-action-status.sh`:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/check-comments.sh <issue|pr> <NUMBER> "$BEFORE_TS"
```

Exit codes:
- **0** — new comments found. Proceed.
- **1** — no new comments. Check action status below.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/check-action-status.sh <issue|pr> <NUMBER> "$BEFORE_TS"
```

Exit codes:
- **0** — dispatch action still running. Sleep 60 seconds, retry.
- **1** — nothing happening. Sleep 60 seconds, retry. Max 24 retries.
- **2** — dispatch action failed. Report failure with URL.

---

## Constraints

- Always wait for fullsend to respond before advancing phases.
- Check labels after every agent phase — route on labels, not assumptions.
- Only include new, unaddressed feedback in `/fs-fix` commands.
- Run local tests after PR creation and after each fix round.
- Respect stop labels: `rejected`, `needs-human`, `fullsend-no-fix`.
- Max 10 fix rounds before escalating to user.
- Never force-push. Resolve conflicts via merge commits. Squash-merge PRs.
- Never post `/fs-fix` on fork PRs.
- All GitHub-bound text must pass through `sanitize.sh` — see "Data Sanitization".
