---
name: polish-pr
description: Iteratively fix PR review comments and CI until the PR is merge-ready - zero unresolved threads, Greptile 5/5 (or every summary-body finding addressed), AND required GitHub checks green on the head SHA. Findings can live in inline threads OR only in the summary comment body. When the user explicitly says /polish-pr, mark a draft PR ready for review first (Greptile skips drafts). Fixes -> pushes -> waits for Greptile re-review and CI -> repeats. Use when you want to auto-iterate on a PR until it's clean, or when the user says /polish-pr.
---

# Polish PR to Greptile 5/5 and CI green

Iteratively fix everything Greptile flags - inline review threads AND findings written only in the summary comment body - **and** failing required CI, until the PR is clean. Never merge; the user reviews and merges.

**The done-gate is ALL of these, not any subset:**
1. Zero unresolved review threads, AND
2. The latest Greptile summary is 5/5 - OR its score is <5 but every finding named in its body has already been fixed in a later commit (a stale summary Greptile didn't re-post), AND
3. Required GitHub checks on the **current head SHA** are green (this repo: workflow `Checks`, jobs `swift-core` and `server`, COMPLETED/SUCCESS). Greptile 5/5 with red CI is **not** done.

A 4/5 (or any <5) summary with an unaddressed finding in its **body** is NOT done, even when the inline thread count is zero. Greptile routinely writes a finding as prose in the summary without filing a thread. Read the body. A failing CI job is the same class of finding: fetch the log, fix, push.

**Explicit invoke only for undraft.** Mark a draft PR ready for review only when the user asked for `/polish-pr`. Greptile skips drafts, so a draft loop sits on NO_REVIEW forever.

**Fork caveat:** on a fresh GitHub fork, Actions workflows are disabled until the owner enables them (repo Actions tab, or `gh api -X PUT repos/{owner}/{repo}/actions/workflows/{workflow_id}/enable`). If the `Checks` workflow never appears on PR commits, enable it first - the CI gate cannot go green otherwise.

## Step 1: Get PR context

```bash
PR_NUMBER=$(gh pr view --json number -q .number)
OWNER=$(gh repo view --json owner -q .owner.login)
REPO=$(gh repo view --json name -q .name)
```

If the PR is a draft and polish-pr was explicitly requested: `gh pr ready $PR_NUMBER`, then wait for the `Greptile Review` check to appear on the head SHA.

## Step 2: Check current Greptile score AND read the summary body

The `Confidence Score` lives in the Greptile **summary** comment, not necessarily the last comment. Parse the most recent comment that has one, and when the score is <5, print the summary body - it is the fallback source of findings when Greptile filed no thread.

```bash
gh pr view $PR_NUMBER --json comments | python3 -c "
import json, sys, re
d = json.load(sys.stdin)
greptile = [c for c in d['comments'] if 'greptile' in c.get('author', {}).get('login', '').lower()]
if not greptile:
    print('NO_REVIEW'); exit()
summaries = [c for c in greptile if 'Confidence Score' in c['body']]
if not summaries:
    print('NO_SUMMARY_YET'); print('SCORE=0'); exit()
last = summaries[-1]
m = re.search(r'Confidence Score: (\d+)/5', last['body'])
score = int(m.group(1)) if m else 0
print(f'Score: {score}/5'); print(f'SCORE={score}')
if score < 5:
    print('--- SUMMARY BODY ---'); print(last['body'])
"
```

- **SCORE=5** -> likely done; still confirm zero unresolved threads (Step 4) and green CI (Step 2b).
- **SCORE<5** -> NOT done. Extract every concrete finding the body names and treat it like a thread finding in Step 5.
- Only acceptable <5 stop: every body finding already fixed in a later commit, a confirmed re-review produced nothing new, AND CI is green. Report the score as stale.

## Step 2b: Required CI must be green

```bash
gh pr view $PR_NUMBER --json statusCheckRollup --jq '
  .statusCheckRollup[] | select(.name != "Greptile Review") | "\(.name) \(.status) \(.conclusion // "running")"'
```

- `swift-core` / `server` IN_PROGRESS -> keep polling. Not done.
- FAILURE / CANCELLED -> NOT done. `gh run view <id> --log-failed`, fix, push, re-enter from Step 2.
- SUCCESS on the current head -> CI gate passes.
- If no `Checks` runs exist at all on a fork, see the fork caveat above.

## Step 3: Iteration count

```bash
ITER_FILE=/tmp/polish-pr-$PR_NUMBER
ITERS=$(( $(cat $ITER_FILE 2>/dev/null || echo 0) + 1 )); echo $ITERS > $ITER_FILE
```

If ITERS > 10: stop, clean up, report what Greptile is still flagging and that the cap was hit.

## Step 4: Fetch unresolved review threads

```bash
gh api graphql -f query="
query { repository(owner: \"$OWNER\", name: \"$REPO\") { pullRequest(number: $PR_NUMBER) {
  reviewThreads(first: 100) { nodes { id isResolved path line
    comments(first: 10) { nodes { id databaseId body author { login } } } } } } } }" \
| jq -c '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)
  | {threadId: .id, path, line, commentId: .comments.nodes[0].databaseId,
     author: .comments.nodes[0].author.login, body: .comments.nodes[0].body}' | tee /tmp/polish-pr-threads-$PR_NUMBER
```

No unresolved threads but score <5 is the common case: the finding is in the summary body from Step 2. Fix it exactly like a thread finding; there is no thread to reply to, the push clears it.

## Step 5: Fix the issues

Minimal, targeted changes only - nothing unrelated. Decide a disposition for every thread in the Step 4 worklist: FIXED (you actually changed code for it) or SKIP with a concrete reason (wrong for this codebase, conflicts with a platform constraint, false positive). Never mark a thread FIXED without a change that addresses it. Run quality gates before every push:

```bash
swift test                                   # Core package (needs a Mac; CI job swift-core runs it on macos-15)
cd server && npm ci && npm run build && npm test   # only when server/ files were touched
```

No Mac/Xcode available (Linux or cloud agent): say so, skip local gates, and let CI be the gate. Never claim a local build that did not happen.

```bash
git add -A && git commit -m "fix: address PR review comments (iteration $ITERS)" && git push
date -u +"%Y-%m-%dT%H:%M:%SZ" > /tmp/polish-pr-pushts-$PR_NUMBER
```

Then write the disposition file, one line per Step 4 thread - `FIXED` only when this push really addresses it:

```bash
# /tmp/polish-pr-dispo-$PR_NUMBER: per line, "<commentId> FIXED" or "<commentId> SKIP <reason>"
```

## Step 6: Resolve only the threads you actually fixed

Reply and resolve ONLY threads marked FIXED in the disposition file, using identifiers from the Step 4 file - never empty IDs, and never resolve a thread whose finding was not addressed in a pushed commit. For SKIP threads: reply with the reason and leave them unresolved; the done-gate stays open on them until they are fixed or the user overrules.

```bash
COMMIT_SHA=$(git rev-parse --short HEAD)
while IFS= read -r t; do
  [ -z "$t" ] && continue
  THREAD_ID=$(printf '%s' "$t" | jq -r .threadId); COMMENT_ID=$(printf '%s' "$t" | jq -r .commentId)
  DISPO=$(awk -v id="$COMMENT_ID" '$1 == id {print $2; exit}' /tmp/polish-pr-dispo-$PR_NUMBER)
  # Match the disposition FIELD exactly, never the free-form text: a SKIP reason
  # containing the word FIXED (e.g. "SKIP already FIXED upstream") must not resolve.
  case "$DISPO" in
    FIXED)
      gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies -f body="Fixed in $COMMIT_SHA"
      gh api graphql -f query="mutation { resolveReviewThread(input: {threadId: \"$THREAD_ID\"}) { thread { isResolved } } }" ;;
    SKIP)
      REASON=$(awk -v id="$COMMENT_ID" '$1 == id {$1=""; $2=""; print}' /tmp/polish-pr-dispo-$PR_NUMBER)
      gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies -f body="Not applied:$REASON" ;;
    *) echo "no disposition for $COMMENT_ID - not resolving" >&2 ;;
  esac
done < /tmp/polish-pr-threads-$PR_NUMBER
```

A zero unresolved-thread count is only meaningful when every resolution is backed by a fix. Resolving an unaddressed thread makes the done-gate lie.

## Step 7: Poll for Greptile's new review

Greptile re-reviews after a push, usually within 1-5 minutes. **It EDITS the summary comment in place** - `created_at` never moves, `updated_at` does. The reliable re-review signal is the per-commit **`Greptile Review` status check** completing on the new head SHA; the summary edit lands at the same moment. Poll the summary's `updated_at`, new review threads, and the check, up to 10 times 30s apart. Then re-run Steps 2, 2b, and 4 and apply the full done-gate - the poll only says a re-review happened, never that the PR is done.

Still nothing after 10 minutes: wait another 5, re-enter from Step 2. Genuinely stuck: report last score + last CI state with all known findings addressed, and stop.

## Stop conditions

| Condition | Action |
|---|---|
| Zero unresolved threads AND 5/5 AND `Checks` SUCCESS | Done - clean up /tmp/polish-pr-* files and report |
| Zero unresolved AND <5 but every body finding fixed, silent re-review, `Checks` SUCCESS | Done - report score as stale-but-addressed |
| Any `Checks` job FAILURE (even at 5/5) | NOT done - fix CI, push, re-poll |
| Zero unresolved AND <5 with an unaddressed body finding | NOT done - fix it, push, re-poll |
| Unresolved threads > 0 | NOT done - fix them |
| Iterations > 10 | Stop - report remaining issues |
| Same finding reappears after 2 cycles | Stop - report stalled with the recurring finding |

## Notes

- Findings live in two places; clear both: inline threads AND summary-body prose. Zero threads is not clean.
- Don't wait forever for a 5/5 that never comes, and don't stop at a <5 whose body finding is unfixed. The score and CI together tell you which.
- Greptile's re-trigger link is browser-auth-gated; rely on post-push auto review, the status check, and `@greptileai` comments for manual retriggering.
- Draft PRs get no Greptile run. Undraft only on explicit `/polish-pr`.
- Each iteration addresses only what Greptile, reviewers, or CI flagged.
- The resolution trap: snapshotting unresolved threads and later resolving the whole snapshot unconditionally can close findings nobody fixed. Step 5's disposition file is the guard - FIXED means a pushed change addresses the finding; anything else stays unresolved with an explanatory reply.
