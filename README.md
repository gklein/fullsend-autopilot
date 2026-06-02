# fullsend-autopilot

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill that drives an idea from description to merged PR — unattended. It orchestrates the [fullsend](https://github.com/fullsendai/fullsend) pipeline: triage, prioritize, code, review, fix, and merge — all autonomously. Can also start from an existing PR to drive just the review/fix, merge, and retro phases.

## What it does

Give it a bug description, feature request, existing GitHub issue, or PR. The skill will:

1. **Scan** the codebase for relevant context
2. **Create** a detailed GitHub issue (or use an existing one)
3. **Triage** via `/fs-triage` — answer clarifying questions from code if needed
4. **Prioritize** via `/fs-prioritize` — get a RICE score
5. **Code** via `/fs-code` — generate a PR
6. **Review & fix** via `/fs-fix` — loop up to 10 rounds until approved
7. **Merge** the PR and run `/fs-retro`

The skill handles the full state machine: label routing, fork detection, merge conflicts, merge queues, local test runs, and fallback polling.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- [GitHub CLI](https://cli.github.com/) (`gh`) authenticated
- A repository with [fullsend](https://github.com/fullsendai/fullsend) workflows configured

## Installation

Copy this skill into your Claude Code skills directory:

```bash
cp -r fullsend-autopilot ~/.claude/skills/
```

## Usage

Invoke from Claude Code with a description, issue reference, or PR reference:

```
/fullsend-autopilot Add rate limiting to the /api/upload endpoint
```

```
/fullsend-autopilot #42
```

```
/fullsend-autopilot https://github.com/owner/repo/issues/42
```

Start from an existing PR (skips issue/triage/prioritize/code, jumps to review/fix):

```
/fullsend-autopilot !42
```

```
/fullsend-autopilot PR #42
```

```
/fullsend-autopilot https://github.com/owner/repo/pull/42
```

When using `#NNN`, the skill auto-detects whether it's an issue or PR.

## How it works

The skill is defined in `SKILL.md` and uses helper scripts in `scripts/` for GitHub API interactions:

| Script | Purpose |
|--------|---------|
| `wait-for-run.sh` | Find and watch a fullsend workflow run to completion |
| `check-comments.sh` | Poll for new comments since a timestamp |
| `check-action-status.sh` | Check if a dispatch action is running or failed |
| `check-labels.sh` | Fetch labels to route through the state machine |
| `find-pr-for-issue.sh` | Locate the PR created by the code agent |
| `get-review-feedback.sh` | Collect review decisions, inline comments, and action status |

## License

[MIT](LICENSE)
