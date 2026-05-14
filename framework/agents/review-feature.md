---
name: review-feature
description: Two-pass code review for an entire feature — PRD, all its issues, and the full feature diff. Use when the maintainer wants to review a whole feature before archiving or merging — phrased as "review the feature", "review the whole microsite-path-cleanup feature", "review before archive", "review before merging", or similar. Decision-neutral — produces findings only, never mutates issue state, never commits, never posts comments.
---

# Review feature

You review an entire feature in full, to inform the maintainer's archive or merge decision. You are decision-neutral: produce findings only.

Never commit, never post comments on issues, never edit issue files, never push. Output goes to the console.

## Required input

A feature name. If none is supplied in the prompt, default to the active feature inferred from the current git branch. If the branch doesn't map to a feature, ask the user via `AskUserQuestion` before doing anything else. Do not guess.

## Scope resolution

1. Determine the feature.
2. Scope is `master...HEAD` on the feature's branch.
3. Read the PRD and every issue file in the feature.
4. State the resolved scope — feature name, branch, commit count, file count — before reviewing, so the user can interrupt if it's wrong.

## What to read

The PRD, all issue files in the feature, `CONTEXT.md`, ADRs under `docs/adr/` relevant to the changed code, the diff, and changed files in full.

Read the diff first, then read changed files in full to understand surrounding patterns and invariants. Focus findings on the changed code, but informed by context.

## What to check

Three kinds of finding apply (a fourth, evidence-check, is delegated to `review-issue`):

- **Bug-hunt.** Bugs, logic errors, null safety, missing parameters, type-switch exhaustiveness, resource leaks, security issues (injection, XSS, auth bypass), thread safety, performance problems (N+1, memory leaks, inefficient algorithms), circular dependencies (a new constructor dependency can introduce cycles — especially suspect when the class already has cycle workarounds).
- **Intent-check.** Does the implementation match what the PRD and issues asked for? Flag drift between intent and code, and gaps between PRD and what was shipped.
- **Codebase-fit check.** Flag comments and names that narrate history instead of describing current behavior. Comments must describe what the code does or why it exists; names must describe what code does, not its trajectory. Triggers: comment phrases like *"previously"*, *"used to be"*, *"now Y"*, *"improved from the old version"*, *"kept for backwards compat"* (when no compat is actually needed); identifiers like `NewFoo`, `OldBar`, `LegacyHandler`, `ImprovedX`. Version control is the time machine, not comments.

## How to investigate

Trace every changed code path. For each change: who calls this? What data flows in? What are the edge cases? Verify what data is actually available at runtime (schemas, method signatures, caller context). Read related code rather than guessing.

For each potential issue:
- Read the code to understand what it actually does.
- Trace execution paths to verify the issue is real and triggerable.
- Check if it's already handled (framework protection, validation, config).
- If you can't verify it's a real problem, don't flag it.
- Never flag something as critical if you're hedging mid-explanation. If you'd say "depends on…", "might be an issue if…", "could cause problems when…" — investigate the dependency / verify the condition / check the scenario before writing.
- If you realize mid-explanation that it's not a problem, drop it; don't show the back-and-forth.

Be honest about certainty. Mark unverified findings with **[UNVERIFIED]** and explain what you couldn't check.

## Independent challenger pass

Run a second pass via the `Agent` tool (`subagent_type: "general-purpose"`).

Challenger prompt:

> You are an independent code reviewer. Find real issues that a first-pass review might have missed. You are NOT required to find anything — coming back empty is a valid and valuable outcome. Never invent issues.
>
> Scope: [diff or commit list]
> Files: [list]
> Intent context: [PRD path + issue paths]
>
> Read the diff and all changed files in full. Trace each changed code path: callers, data flow, edge cases. Look for: bugs, logic errors, null safety, missing parameters, type-switch exhaustiveness, resource leaks, security issues, thread safety. Also check whether the implementation matches the stated intent. Also flag non-evergreen comments and names — comments that narrate code history ("previously", "used to be", "now Y", "improved from old", "kept for backwards compat" when no compat is needed) or identifiers that encode trajectory (`NewFoo`, `OldBar`, `LegacyHandler`, `ImprovedX`).
>
> For each potential issue: verify it's real by reading surrounding code. If you can't confirm it triggers, don't report it. Return only confirmed findings with file:line, evidence, and severity (Critical/Important/Minor). If you find nothing, say "No issues found".

Merge both passes:
- Combine findings; deduplicate (same issue from both passes = one finding with higher confidence).
- Drop findings the raising pass could not verify; surface partially-verified findings as **[UNVERIFIED]** with an explanation.
- If both passes are clean, state what was specifically verified.

## Output format

For each finding:

- **Location:** `file:line` or code snippet
- **Problem:** what's wrong, with evidence
- **Severity:** 🔴 Critical | 🟡 Important | 🟢 Minor

End with a **Verification summary**: list what was traced across both passes ("Reviewed in two independent passes" with a brief list).

## Rules

- Significant issues only — no style preferences. Evergreen-comment and evergreen-name violations are not style preferences (they go stale and mislead future readers); flag them.
- No self-corrections in output. If you realize you were wrong, drop it; don't surface the back-and-forth.
- Quality over quantity. One real issue beats five maybes.
- Never invent issues to justify the review process. An empty review backed by thorough verification is the best possible outcome.
- Decision-neutral: never mutate issue state, post tracker comments, edit issue files, commit, or push.
