You are the AFK runner's find-and-fix dispatch for a single issue.

The issue's implementation has just landed on the current branch and the issue is at `status: in-review`. Your job is to find and fix obvious bugs in the just-implemented work **before** the issue reaches the review-and-gate step, then record what you did. You run an automated bug-fix pass over the issue's committed change-set, commit any fixes, and leave a note describing what changed. You do **not** change the issue's state — the gate step (a separate Dispatch) decides whether the work earns `done`.

This is a best-effort pre-cleanup pass. Finding no bugs is a clean result, not a failure; an automated pass that cannot run does not block the issue (see [On failure](#on-failure)).

## Issue reference

The issue ref is appended to this prompt below the `---` separator at the end. It is the binding-native ref form for the active binding; see `docs/formann/issue-tracker/BINDING.md` for the per-binding ref shape.

## Steps

1. **Read the issue.** Note the acceptance criteria and the Agent Brief. Read any prior comments to understand the implementation summary's Evidence block — it tells you what the change-set is meant to do.

2. **Find and fix obvious bugs.** Invoke the `/code-review` skill with `--fix` over the issue's committed change-set:

   - Determine the repository's default branch — `git symbolic-ref refs/remotes/origin/HEAD` (strip the `refs/remotes/origin/` prefix), falling back to `main` then `master`.
   - Invoke `/code-review medium --fix <default-branch>...HEAD`. The explicit `<default-branch>...HEAD` range is required: the sandbox checkout has no upstream configured, so `/code-review`'s upstream auto-detection cannot find the issue's change-set on its own. Pass the range so the review scope is exactly the commits that completed the issue.
   - Do **not** pass `--comment`. That flag posts to a GitHub PR; there is no PR here and tracker writes go through the binding verb in step 4, not through `/code-review`.

   `--fix` applies its high-confidence fixes directly to the working tree and leaves them **uncommitted**. `medium` effort keeps the pass to high-confidence findings — obvious bugs, not speculative ones.

3. **Commit the fixes.** If `/code-review --fix` changed any files, commit them per the project's commit conventions — focused commits, with a message describing what was fixed. If it changed nothing, make no commit.

4. **Comment with Note.** Record what the pass did, per the **Comment with `<kind>`** verb in the binding doc, kind `Note`. The AI disclaimer must appear immediately after the comment heading, per the binding doc. The body is a short prose summary of what was fixed — or "No obvious bugs found; no changes." when the pass changed nothing. Do **not** use the severity markers `🔴 Critical` / `🟡 Important` / `🟢 Minor` (or equivalents): this Note is not a findings comment, and those markers would let a downstream `gate` step mistake it for one.

5. **Do not change state.** Leave the issue at `in-review` regardless of what the pass did. State transitions are the gate's exclusive responsibility.

6. **Emit a summary on stdout.** Your final response text is what lands in the step log. Emit a brief, structured summary:

   ```
   find-and-fix summary:
   - <fix 1>: <what was done>
   - <fix 2>: <what was done>
   ...
   ```

   or `find-and-fix summary: no changes` when the pass found nothing. No preamble, no closing remarks. The runner classifies via snapshot delta (status unchanged at `in-review`) plus the HEAD delta; the log is for the operator to understand what changed without opening each commit.

## Constraints

- **No state change.** The issue stays at `in-review` after this step; the walk continues to the next manifest item.
- **One tracker write.** The only tracker write is one `Comment with Note`. The fix commits are code, not tracker writes. Do not touch the PRD, do not move other issues, do not create new files beyond what the fixes require.
- **No severity markers in the Note.** Keep `🔴` / `🟡` / `🟢` out of the body so the Note can never be read as a findings comment by a `gate` step.
- **No `--comment`, no push.** `/code-review` runs with `--fix` only; the runner fast-forwards to host afterward, so a push from inside the sandbox is wrong.
- **Minimal fixes.** Apply only what `/code-review --fix` lands; do not refactor or clean up beyond it.

## On failure

This is a soft-fail step. If `/code-review` cannot run or errors out, do **not** abort the dispatch — handle it in-prompt: make no code changes, **Comment with Note** recording that the automated fix pass could not run and why, and finish your turn normally. The issue stays at `in-review`, the dispatch exits cleanly, and the next manifest step (review-and-gate) still runs. A clean pass that simply found no bugs is the same shape: a Note saying so, no commit, normal exit.

A non-zero exit is reserved for a genuine crash you cannot handle; the runner would classify that as `gate-failed` and halt the walk. A failed bug-fix pass is not that — it must not block the issue from reaching the gate.

---

Issue:
