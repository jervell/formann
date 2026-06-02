---
name: feedback-loop
description: Iterate on output through a feedback loop — a worker sub-agent produces a draft, a validator sub-agent independently checks it, and the worker revises until the validator signs off (or three refinement rounds elapse). Use for fact-checked reviews, draft refinement, or any task where independent validation improves the result. Triggers include /feedback-loop and explicit requests for "review with verification", "fact-checked review", or "feedback loop".
---

Orchestrate two sub-agents — a worker and an independent validator — until the validator signs off or three refinement rounds elapse.

**Issue of substance** — a defect that materially fails the task: a factual error, a missing required element, a violation of stated criteria. Style notes and minor slips the validator itself flags as non-blocking don't count. If the validator says "the output is sound" or equivalent, treat it as sign-off.

## Flow (round N, starting at 1)

1. **Spawn worker** with `Agent` using:
   - N = 1: **Template A**.
   - N > 1: **Template B**.

   Capture the worker's output **W(N)** and the spawned agent id — the `Agent` tool's return text trails it as `agentId: <hex>`.

2. **Spawn validator** following the **Template C procedure**.

   Capture verdict **V(N)**.

3. If **V(N)** has no issues of substance, stop and reply with **W(N)** verbatim.

4. If N = 4 (three refinements done), stop and reply with **W(N)** plus 1–3 sentences naming any unresolved disagreements.

5. Otherwise increment N and return to step 1.

## Spawn templates

### Template A — worker, round 1

Pass the verbatim user message — nothing prepended, appended, or wrapped. No slot markers, no protocol context. The sub-agent receives the message as a literal string; if it starts with a slash command (e.g. `/review`), the sub-agent will typically recognise it and invoke the matching skill via the Skill tool. Wrapping or paraphrasing would suppress that recognition and break composability.

### Template B — worker, round N > 1

Render round N−1's worker transcript to a per-session temp file, then point the round-N worker at it. The render preserves turn order and inlines tool calls and results, so the worker reads one continuing chat.

```
mkdir -p "/tmp/feedback-loop/$CLAUDE_CODE_SESSION_ID"
"${CLAUDE_SKILL_DIR}/scripts/render-transcript.py" {agentId of round N−1 worker} > "/tmp/feedback-loop/$CLAUDE_CODE_SESSION_ID/round-{N−1}.txt"
```

Spawn the round-N worker with this prompt — fill in the path you just wrote:

```
Your prior turns are in `{path}` — read it; that is the conversation we've been having. The validator flagged issues in your previous output. Revise to address them. Keep elements the validator did not challenge.

<<VALIDATOR FINDINGS>>
{V(N−1)}
<<END>>
```

### Template C — validator (procedure)

Spawn the validator with `Agent`. The prompt has three parts in order:

1. **Criteria preamble.** Derive what "good" means for this task:
   - If the user's task starts with a slash command (e.g. `/review`), read that skill's SKILL.md first and use its output spec as the criteria source.
   - Otherwise, infer reasonable criteria from the task description itself.

2. **Invariants** — include these verbatim in every validator prompt:
   - If the worker cites sources, verify the citations directly. Never trust the worker's quotes.
   - Judge each finding as a real defect against the criteria, not just citation accuracy.
   - Flag anything material the worker missed, measured against the user's task.
   - Output a verdict — sign-off or itemised defects.

3. **Slots:**
   ```
   <<USER TASK>>
   {verbatim user message}
   <<END>>

   <<OUTPUT TO VALIDATE>>
   {W(N)}
   <<END>>
   ```

The procedure has no step for prior validator output — keep it that way; a validator that sees its earlier verdicts starts defending them.

## Constraints

- Run sub-agent calls synchronously — never pass `run_in_background`.
- Every spawn is a fresh `Agent` call. Template B simulates continuation via rendered transcript; do not rely on `SendMessage` or agent resumption.