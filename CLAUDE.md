# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Claude Code skill that takes a bug description or feature request and drives it through the full [fullsend](https://github.com/fullsendai/fullsend) pipeline — issue creation, triage, prioritize, code, review/fix loop, merge, retro — unattended.

## Linting

```bash
shellcheck ${CLAUDE_SKILL_DIR}/scripts/*.sh
```

All scripts must pass ShellCheck with zero warnings.

## Architecture

The skill has two layers:

1. **`SKILL.md`** — the prompt. Defines the 8-phase state machine (Phase 0–7) that Claude Code follows. Contains the routing logic (label-based), retry policies, and constraints. This is what Claude executes — it's not documentation, it's the program.

2. **`scripts/`** — shell helpers called by the prompt via `${CLAUDE_SKILL_DIR}/scripts/*`. Each script does one thing and communicates results via exit codes and stdout:

| Script | Responsibility | Exit codes |
|---|---|---|
| `wait-for-run.sh` | Find a workflow run by actor+timestamp+command, watch to completion | 0=success, 1=not found, 2=failed |
| `check-comments.sh` | Fetch issue/PR comments since a timestamp | 0=found, 1=none |
| `check-action-status.sh` | Check if a dispatch action is running or failed | 0=running, 1=nothing, 2=failed |
| `check-labels.sh` | Fetch labels on an issue or PR | 0=ok, 1=error |
| `find-pr-for-issue.sh` | Locate the PR linked to an issue (prefers bot PRs) | 0=found, 1=not found |
| `get-review-feedback.sh` | Collect review decisions, inline comments, action status | always 0 |

Scripts share a common pattern: resolve `REPO` via `gh repo view`, validate args, call `gh api`, parse with `jq`. All use `set -euo pipefail`.

## Key design decisions

- **Actor+timestamp+title+command matching** — workflow runs are found by matching the current `gh` user, a timestamp, the issue/PR `display_title`, and optionally verifying the run contains a non-skipped `dispatch / <Command>` job. This prevents latching onto runs from other issues or prior phases.
- **Label-driven routing** — the state machine routes on GitHub labels (`ready-to-code`, `needs-info`, `blocked`, `ready-for-merge`, etc.), not on comment content parsing.
- **Fork safety** — fork PRs are detected once (Phase 4.3) and block `/fs-fix` in Phase 5, because the fix agent can't push to fork branches.
- **Fallback polling** — if `wait-for-run.sh` can't find a run (GitHub webhook lag), the skill falls back to polling with `check-comments.sh` + `check-action-status.sh`.

## Shell script conventions

- Shebang: `#!/usr/bin/env bash`
- First line after shebang: `set -euo pipefail`
- Args validated with `${1:?Usage: ...}` pattern
- All `gh api` calls use `2>/dev/null` with `|| echo "[]"` or `|| echo ""` fallbacks
- No hardcoded repos, users, or paths — everything derived at runtime from `gh` context
- PRs are squash-merged (`--squash`), not merge-committed — conflict resolution still uses merge commits
