# `afk-runner.md` documents a gate tracker-commit subject the gate doesn't emit

`framework/afk-runner.md:229` claims the review-and-gate stage, under
local-markdown, "lands as a single `tracker:` commit
(`tracker: review <ref> → done` or `tracker: review <ref> → blocked`)."

The actual gate doesn't emit that subject. The gate prompt
(`framework/runner/steps/review-and-gate.md`) doesn't lock a subject
template, so the agent picks the phrasing. Observed in two smoke runs
on 2026-05-26 (`framework/runner/tests/smoke.bats` propagated +
parked scenarios): `tracker: smoke/01 review (AFK gate) — clean; set done`.

The same documented format also appears as synthetic fixtures in the
runner unit tests (`framework/runner/tests/run-the-queue.bats` lines
1065, 1124, 1772, 1846, 1879). Those tests don't actually run the
gate — they create commits with that subject by hand to exercise
post-gate pure-logic code paths. That usage isn't drift per se, but
it reinforces the documented format inside the test suite while the
production gate doesn't honour it.

The "single commit" half of the doc's claim is unverified — the smoke
runs only assert the branch tip is a `tracker:` commit, not the total
count. The gate performs two BINDING-MD verbs (`Set the state to done`
+ `Comment with Review (AFK gate)`); whether the agent bundles them
into one commit or two is not pinned anywhere I can find.

Two ways out, roughly in order of decreasing scope:

- **Lock the subject in the gate prompt.** Add a "Commit with subject
  `tracker: review <ref> → <verdict>`" line to `review-and-gate.md`,
  matching the doc. Removes drift; constrains the agent.
- **Update the doc to describe the current reality.** Say "lands as
  one or more `tracker:` commits whose subjects start with `tracker:`
  and reflect the verdict" — or similar — and stop claiming a literal
  subject.

The second is cheaper and matches how the rest of the binding contract
treats commit subjects (`tracker:` prefix is the contract; phrasing
beyond that is the producing skill's call). The smoke test's loosened
assertion (`^tracker:.*<ref>.*done`) is already aligned with that
reading.