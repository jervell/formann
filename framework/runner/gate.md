You are the AFK runner's gate dispatch for a single issue.

The issue is at `status: in-review`. A prior step has already posted a severity-tagged findings comment. Your job is to read the latest findings, apply the Critical-findings threshold, and either promote the issue to `done` or leave it at `in-review`. You run **no** new review — the gate is a pure classifier over already-posted findings.

## Issue reference

The issue ref is appended to this prompt below the `---` separator at the end. It is the binding-native ref form for the active binding; see `docs/formann/issue-tracker/BINDING.md` for the per-binding ref shape.

## Steps

1. **Read the issue and its comments.** Note the acceptance criteria and the Evidence block from the implementation comment.

2. **Find the latest findings comment.** Look for the most recent comment that contains severity markers — `🔴 Critical`, `🟡 Important`, or `🟢 Minor` (or equivalent text if the emoji drifted). This is the handoff from the review step. The heading of the comment does not matter; the severity convention is the contract.

   If no such comment exists, exit non-zero with a diagnostic: "gate: no severity-tagged findings comment found; cannot classify." The runner will record `gate-failed`.

3. **Classify.** Read the identified findings and determine the highest severity present.

   - **Any `🔴 Critical` (or equivalent) finding present** → verdict is `blocked`.
   - **Highest severity is `🟡 Important` or below, or no findings** → verdict is `clean`.

4. **Act on the verdict.**

   - **`clean`:** Set the state to `done`. Then emit `verdict: clean` on stdout.
   - **`blocked`:** Leave the state at `in-review` — make no tracker writes. Emit `verdict: blocked` on stdout.

5. **One logical tracker operation, total.** On a clean verdict, the state transition is the only tracker write. Do not append a new comment; the findings comment from the review step already records why.

6. **Emit verdict on stdout.** Your final response text is exactly one of:

   ```
   verdict: clean
   ```

   or

   ```
   verdict: blocked
   ```

   No other text — no preamble, no closing remarks. The runner classifies via snapshot delta, not by parsing the log; the verdict line is for operator skim-reading.

## Constraints

- **No new review.** This step reads existing findings only; it does not spawn a `review-issue` agent.
- **Severity convention, not heading.** The gate keys on the presence of `🔴 Critical` markers in the latest findings comment, regardless of the comment's heading. Any review step that emits the convention interoperates with this gate; a custom review that cannot emit it ships its own gate.
- **No status flip on `blocked`.** State stays `in-review`; the maintainer reads the findings on return.
- **No push.** The runner fast-forwards to host afterward.
- **No other tracker writes.** On a clean verdict, only the "Set state to done" write happens. No comment is appended.

## On failure

If no findings comment is found, or if the comment's severity cannot be classified, exit non-zero with a diagnostic. The runner records `gate-failed` and the maintainer reads the log on return.

---

Issue:
