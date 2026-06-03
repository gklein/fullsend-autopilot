---
name: fullsend-autopilot
description: >
  Orchestrates the complete fullsend pipeline — scans the codebase, creates
  or locates a GitHub issue, then drives triage, code, review/fix,
  merge, and retro to completion unattended. Can also start from an existing
  PR to drive just the review/fix, merge, and retro phases. Invoked when
  a user wants to go from an idea, issue, or PR reference to a merged PR
  with zero manual steps.
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

**Input:** `$ARGUMENTS` — free-text description, GitHub issue/PR URL,
`#NNN` (auto-detected as issue or PR), `!NNN` (PR), or `PR #NNN` (PR).

## Progress

Print this checklist at the start. Update after each phase.

**Standard checklist (issue or new-issue mode):**

```
- [ ] Phase 0 — Sync
- [ ] Phase 1 — Issue
- [ ] Phase 2 — Triage
- [ ] Phase 3 — Code
- [ ] Phase 4 — Review/Fix
- [ ] Phase 5 — Merge
- [ ] Phase 6 — Retro
```

**PR-mode checklist** (when input is a PR reference):

```
- [ ] Phase 0 — Sync
- [-] Phase 1 — Issue (skipped — PR mode)
- [-] Phase 2 — Triage (skipped — PR mode)
- [-] Phase 3 — Code (skipped — PR mode)
- [ ] Phase 4 — Review/Fix
- [ ] Phase 5 — Merge
- [ ] Phase 6 — Retro
```

Report after each phase: `[autopilot] Phase N/6 — <Name> — <outcome>`

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

## Input Detection

Parse `$ARGUMENTS` to determine the operating mode **before any phase runs**.
Check patterns in this order (first match wins):

| Input form | Mode | Extracted |
|---|---|---|
| `https://github.com/.../pull/NNN` | **PR** | `PR_NUMBER` = NNN |
| `!NNN` | **PR** | `PR_NUMBER` = NNN |
| `PR #NNN` or `pr #NNN` | **PR** | `PR_NUMBER` = NNN |
| `https://github.com/.../issues/NNN` | **Issue** | `ISSUE_NUMBER` = NNN |
| `#NNN` | **Ambiguous** | NUMBER = NNN — disambiguate below |
| Anything else | **New-issue** | — |

### Disambiguate `#NNN`

When the input is bare `#NNN`, determine whether it is a PR or an issue:

```bash
gh pr view NNN --json number --jq .number 2>/dev/null
```

If this succeeds (exit 0), `#NNN` is a PR → **PR mode** with `PR_NUMBER` = NNN.
If it fails (exit 1), treat as an issue → **Issue mode** with `ISSUE_NUMBER` = NNN.

### PR mode setup

Verify the PR exists and is open:

```bash
gh pr view <PR_NUMBER> --json state,number,title,headRefName \
  --jq '{state, number, title, branch: .headRefName}'
```

If the PR state is `MERGED` or `CLOSED`, **STOP** with a message:
"PR #NNN is already <state>. Nothing to do."

Attempt to discover a linked issue:

```bash
ISSUE_NUMBER=$(gh pr view <PR_NUMBER> --json body --jq '.body' 2>/dev/null \
  | grep -oiE '(closes|fixes|resolves|close|fix|resolve) #([0-9]+)' \
  | head -1 | grep -oE '[0-9]+' || echo "")
```

If empty, `ISSUE_NUMBER` remains unset — Phase 6 will adapt.

**Skip Phases 1–3. Proceed to Phase 0 (PR variant), then Phase 4.**

### Issue mode

Extract `ISSUE_NUMBER`. Proceed to Phase 0, then Phase 2.

### New-issue mode

Treat `$ARGUMENTS` as a free-text description. Proceed to Phase 0, then
Phase 1.

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

3. **PR mode:** Check out the PR branch and determine fork status:
   ```bash
   gh pr checkout <PR_NUMBER>
   ```
   ```bash
   REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
   IS_FORK=$(gh api "repos/${REPO}/pulls/<PR_NUMBER>" \
     --jq 'if .head.repo.full_name != .base.repo.full_name then "FORK" else "SAME" end')
   ```

4. **Issue/new-issue mode:** If an existing issue is provided, check for a
   feature branch:
   ```bash
   git branch -r --list "origin/agent/<ISSUE_NUMBER>-*"
   ```
   If found, check it out instead and pull latest.

---

## Phase 1 — Create or locate the issue

> **PR mode:** Skip this entire phase. Phases 2 and 3 are also skipped.
> Jump directly to Phase 4.

### 1.1 Detect input type

Input detection is handled in the "Input Detection" section above.
If **issue mode**, skip to Phase 2. If **new-issue mode**, continue to 1.2.

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

> **PR mode:** Skip this phase entirely.

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

### 2.4 Wait for triage outcome labels

Poll every 60 seconds until a routing label appears:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/wait-for-label.sh issue <ISSUE_NUMBER> \
  "ready-to-code|triaged|needs-info|duplicate|blocked"
```

Route based on labels:

| Label | Route |
|-------|-------|
| `needs-info` | AI answers from code. Pull latest, scan for answers, **sanitize** and post comment. Wait for re-triage. If still `needs-info`, **STOP**. |
| `duplicate` | **STOP.** Report the original issue. |
| `blocked` | **STOP.** Report the blocker. |
| `ready-to-code` / `triaged` | Proceed to Phase 3 (Code). |
| None of the above | **STOP.** Print labels. |

When posting a `needs-info` answer, pipe through the sanitizer:

```bash
gh issue comment <ISSUE_NUMBER> --body "$(bash ${CLAUDE_SKILL_DIR}/scripts/sanitize.sh <<'INFO_EOF'
<answer using repo-relative paths, no secrets or local env data>
INFO_EOF
)"
```

---

## Phase 3 — Code

> **PR mode:** Skip this phase entirely.

### 3.0 Pre-check blocking labels

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/check-labels.sh issue <ISSUE_NUMBER>
```

- If `blocked` → **STOP.** Report the blocker.
- If `pr-open` → **STOP.** Report "Human PR already exists for this issue."

### 3.1 Post the code command

```bash
BEFORE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh issue comment <ISSUE_NUMBER> --body "/fs-code"
```

### 3.2 Wait for the code agent

The code agent may run for several minutes. Use **`run_in_background: true`**:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/wait-for-run.sh issue <ISSUE_NUMBER> "$BEFORE_TS" Code
```

Handle exit codes same as Phase 2.

### 3.3 Find the PR

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

Note the result. If `FORK`, the fix agent will be blocked in Phase 4.

### 3.4 Local test run

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
the first `/fs-fix` comment in Phase 4.

---

## Phase 4 — Review and fix loop

> **Role constraint:** In this phase, the local agent's job is to
> COLLECT review feedback, COLLECT CI and local test failures, ANALYZE
> whether failures are code bugs or stale tests, and RELAY everything
> to `/fs-fix`. **Never modify application code, test code, or push
> commits directly.** All fixes go through the remote fix agent via
> `/fs-fix`.

> In **PR mode**, `PR_NUMBER` and `IS_FORK` are already set from Input
> Detection and Phase 0. Phase 3.4's local test run has not occurred yet,
> so perform it now before entering the review loop.

### 4.0 Initial local test run (PR mode only)

If entering Phase 4 from PR mode (Phase 3 was skipped), run the local
test suite first. The PR branch is already checked out from Phase 0.

Detect the test framework and run tests:
- Go: `go test ./...` or `make test` / `make go-test`
- Python: `pytest` or `python -m pytest`
- Node: `npm test`
- Make: `make test` if a Makefile with a `test` target exists

Capture any test failures — test name, file, error output. **Sanitize
all test output** (strip absolute paths, replace with repo-relative).
If failures are found, they will be included as additional context in
the first `/fs-fix` comment in step 4.6.

---

This loop continues until the PR is approved with no outstanding
feedback, or 10 fix rounds are exhausted.

Initialize: `FIX_ROUND=0`

### 4.1 Wait for review checks

```bash
gh pr checks <PR_NUMBER> --watch --fail-fast
```

Run with **timeout 600000**. If timeout, fall back to polling
(see Appendix).

### 4.2 Collect review feedback and CI failures

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/get-review-feedback.sh <PR_NUMBER>
```

Check the `ACTION STATUS` section first:
- If **"AGENT STILL RUNNING"** — sleep 60, retry step 4.1.
- If **"AGENT JOB FAILED"** — report failure with URL and stop.

Check the `CI CHECK FAILURES` section for failed non-dispatch checks
(test suites, linters, etc.). These will be included in the `/fs-fix`
comment at step 4.6.

### 4.3 Wait for review outcome labels

Poll every 60 seconds until a routing label appears:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/wait-for-label.sh pr <PR_NUMBER> \
  "ready-for-merge|requires-manual-review|rejected|needs-human|fullsend-no-fix|changes-requested|approved"
```

| Label | Route |
|-------|-------|
| `ready-for-merge` | Check for open items first. If none, Phase 5. If items remain, proceed to 4.4. |
| `requires-manual-review` | AI attempts to address. If still flagged after fix, **STOP**. |
| `rejected` | **STOP.** |
| `needs-human` | **STOP.** |
| `fullsend-no-fix` | **STOP.** |
| None of the above | Changes requested → proceed to 4.4. |

### 4.4 Filter to new feedback only

Build a list of **new-only** items: unaddressed inline comments, updated
comments, regressions, and local test failures. Exclude items already
fixed that have not regressed.

### 4.5 Check for fork PR

If the fork check (from Phase 0 step 3 in PR mode, or step 3.3 in
issue mode) returned `FORK`, **STOP** and report:
"Fork PR — fix agent blocked for security. Manual fixes required."

### 4.6 Post /fs-fix with content

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

## CI test failures

<For each failed CI check (from get-review-feedback.sh CI CHECK FAILURES):
- Check name and failure description
- Link to failed check run if available>

## Local test failures

<For each local test failure (if any):
- Test name and file (repo-relative)
- Error output (sanitized — no absolute paths or env values)
- Classification: [CODE FIX] if the test expects correct behavior
  and the code is wrong, or [TEST UPDATE] if the app behavior
  legitimately changed and the test assertion is stale
- Analysis: what is wrong and what should change>

## Fix guidance

Fix application code first. Only update test assertions if the code
change is correct and the test expectation is stale — never adapt a
test to hide a code bug.

FIX_EOF
)"
```

### 4.7 Wait for fix, then review

**Important:** Pass the literal timestamp value from 4.6, not a variable:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/wait-for-run.sh pr <PR_NUMBER> "<REVIEW_TS_VALUE>" Fix
```

After the fix agent finishes, wait for review checks:

```bash
gh pr checks <PR_NUMBER> --watch --fail-fast
```

### 4.8 Re-run local tests

Pull the latest fix-agent changes:

```bash
git pull origin <PR_BRANCH>
```

Run the same test suite as step 3.4 / 4.0. If all tests pass, proceed
to 4.9.

If tests fail, **analyze each failure** — read the failing test and the
code it exercises. Classify:

- **Code bug** — the test expects correct behavior but the code is
  wrong. Tag as `[CODE FIX]` in the next `/fs-fix`.
- **Stale test** — the app behavior legitimately changed and the test
  assertion is outdated. Tag as `[TEST UPDATE]` in the next `/fs-fix`.

Do NOT fix code or tests locally. Failures feed into the next loop
iteration via step 4.6.

### 4.9 Loop back to 4.2

Continue until APPROVED with no open items and tests pass, or 10 fix
rounds exhausted → **STOP**.

---

## Phase 5 — Merge

### 5.1 Wait for checks and verify approval

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

If the result is empty or not `APPROVED`, sleep 60 seconds and retry.
Max 20 retries (~20 minutes). If still not `APPROVED` after retries,
go back to Phase 4.

### 5.2 Check for merge conflicts

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

### 5.3 Merge the PR

Merge directly. If merge queue required, retry with `--merge-queue`:

```bash
gh pr merge <PR_NUMBER> --squash --delete-branch
```

```bash
gh pr merge <PR_NUMBER> --merge-queue
```

---

## Phase 6 — Cleanup and retrospective

1. Close the issue if known and still open:
   ```bash
   # Only if ISSUE_NUMBER is set (skip in PR mode with no linked issue)
   STATE=$(gh issue view <ISSUE_NUMBER> --json state --jq .state)
   gh issue close <ISSUE_NUMBER>  # only if still open
   ```

2. Post `/fs-retro` (do not wait):
   ```bash
   gh pr comment <PR_NUMBER> --body "/fs-retro"
   # Only if ISSUE_NUMBER is set:
   gh issue comment <ISSUE_NUMBER> --body "/fs-retro"
   ```

3. Print pipeline summary:

```
[autopilot] ═══ Pipeline Complete ═══

Issue:    #<NUMBER> — <title> — <url>    (or "N/A — started from PR" if no linked issue)
PR:       #<NUMBER> — <title> — <url>
Triage:   <outcome label>                (or "skipped — PR mode")
Code:     PR created by <author>         (or "skipped — PR mode")
Review:   <disposition>
Fix:      <N> round(s)
Merge:    <direct merge | merge queue>
Retro:    commands sent (results pending)
```

---

## Appendix — Fallback polling

**All polling uses 60-second intervals.** Never use a single long sleep
(e.g. `sleep 600`) followed by one check — always loop.

If `wait-for-run.sh` exits 1 (no run found) or the Bash tool times out,
fall back to a polling loop with `check-comments.sh` and
`check-action-status.sh`. Run this loop directly — **do not sleep for
longer than 60 seconds between checks**:

```bash
for i in $(seq 1 20); do
  COMMENTS=$(bash ${CLAUDE_SKILL_DIR}/scripts/check-comments.sh <issue|pr> <NUMBER> "$BEFORE_TS" 2>&1) && break
  STATUS=$(bash ${CLAUDE_SKILL_DIR}/scripts/check-action-status.sh <issue|pr> <NUMBER> "$BEFORE_TS" 2>&1)
  EXIT_CODE=$?
  if [[ $EXIT_CODE -eq 2 ]]; then
    echo "ACTION FAILED: $STATUS"
    break
  fi
  echo "Poll ${i}/20: waiting 60s..."
  sleep 60
done
```

Exit codes for `check-comments.sh`:
- **0** — new comments found. Proceed.
- **1** — no new comments. Check action status.

Exit codes for `check-action-status.sh`:
- **0** — dispatch action still running. Sleep 60 seconds, retry.
- **1** — nothing happening. Sleep 60 seconds, retry.
- **2** — dispatch action failed. Report failure with URL.

For **label polling**, use `wait-for-label.sh` which encapsulates the
60-second polling loop:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/wait-for-label.sh <issue|pr> <NUMBER> "<label-pattern>" [max-retries]
```

Exit codes:
- **0** — matching label found (all labels printed to stdout).
- **1** — max retries exhausted (default 20 retries = ~20 minutes).

---

## Constraints

- Always wait for fullsend to respond before advancing phases.
- Check labels after every agent phase — route on labels, not assumptions.
- Only include new, unaddressed feedback in `/fs-fix` commands.
- Run local tests after PR creation and after each fix round.
- Respect stop labels: `rejected`, `needs-human`, `fullsend-no-fix`.
- Max 10 fix rounds before escalating to user.
- Never modify code or push commits in Phase 4. Relay all fixes through `/fs-fix`.
- Never force-push. Resolve conflicts via merge commits. Squash-merge PRs.
- Never post `/fs-fix` on fork PRs.
- All GitHub-bound text must pass through `sanitize.sh` — see "Data Sanitization".
