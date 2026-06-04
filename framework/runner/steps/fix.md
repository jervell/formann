You are the AFK runner's fix dispatch for a single issue.

The issue is at `status: in-review`. A prior review step has posted a severity-tagged findings comment. Your job is to address the findings by producing commits. You do **not** post a new comment and do **not** change the issue's state — the gate step (a separate Dispatch) will re-evaluate after the fix.

## Issue reference

The issue ref is appended to this prompt below the `---` separator at the end. It is the binding-native ref form for the active binding; see `docs/formann/issue-tracker/BINDING.md` for the per-binding ref shape.

## Steps

1. **Read the issue.** Note the acceptance criteria, the Agent Brief, and the original implementation's Evidence block.

2. **Find the latest findings comment.** Look for the most recent comment that contains severity markers — `🔴 Critical`, `🟡 Important`, or `🟢 Minor` (or equivalent text). This is the handoff from the review step. The comment heading does not matter; the severity convention is the contract.

   If no findings comment exists, exit non-zero with a diagnostic: "fix: no severity-tagged findings comment found; nothing to fix." The runner will record `gate-failed`.

3. **Address the findings.** Work through each finding — Critical first, then Important, then Minor — and fix the issues in the code. Follow the same conventions and constraints as the original implementation. Each fix should be focused and minimal.

4. **Commit.** Group related fixes into one or a few commits. Follow the project's commit conventions. Include a concise commit message that describes what was fixed (not the finding verbatim).

5. **No comment, no state change.** Do not post a new comment to the tracker. Do not change the issue's state. The next manifest step (typically `gate` or `review-and-gate`) will re-evaluate from a clean slate.

6. **Emit a fix summary on stdout.** Your final response text is what lands in the step log. Emit a brief, structured summary:

   ```
   fix summary:
   - <finding 1>: <what was done>
   - <finding 2>: <what was done>
   ...
   ```

   No preamble, no closing remarks. The runner classifies via snapshot delta (HEAD before vs. after); the log is for the operator to understand what changed without opening each commit.

## Constraints

- **No comment.** This step makes no tracker writes of any kind.
- **No state change.** The issue stays at `in-review`.
- **No push.** The runner fast-forwards to host afterward.
- **Severity convention, not heading.** The fix reads whichever comment carries severity markers, regardless of its heading. Any review step that emits the convention interoperates with this fix step.
- **Minimal fixes.** Address what the findings identify; do not refactor or clean up beyond what the findings call out.

## On failure

If no findings comment is found, or if the findings cannot be interpreted as actionable work, exit non-zero with a diagnostic. The runner records `gate-failed` and the maintainer reads the log on return.

---

Issue:
