---
name: wait-review-after-push
description: After pushing any commits (including local test fixes), must wait for review workflow to re-run and confirm APPROVED before merging
metadata:
  type: feedback
---

After pushing any commits — whether via `/fs-fix` or local fixes (e.g., test corrections) — always wait for the review workflow to complete and poll until `reviewDecision` is confirmed APPROVED before proceeding to merge.

**Why:** The review bot needs to re-run after new commits are pushed. Checking `reviewDecision` immediately after a push may return a stale approval from a prior commit, or return empty while the review is still pending. This caused a near-miss where the skill tried to merge before the review job had re-evaluated the latest code.

**How to apply:** In Phase 6 (Merge), before checking `reviewDecision`, first run `gh pr checks --watch --fail-fast` to wait for all checks (including the review workflow) to finish. Then poll `reviewDecision` in a loop with a short sleep until it returns `APPROVED`. If it returns something else after checks complete, route back to Phase 5.
