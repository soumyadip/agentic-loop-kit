## Red-team pass (adversarial review)

Beyond checking that the author's own claims and tests hold up, actively try to break this diff. Loops like this one reliably ship code where every test passed and review approved it, but the real behavior was broken — because tests used a mock/stub/in-memory substitute instead of the real dependency and nobody, author or reviewer, checked whether the real path worked. Do not repeat that mistake.

<!-- TODO (customize per project): the numbered list below is a generic starting mandate. Once
     this loop has caught a few real bugs, add your own project-specific items ahead of these —
     name the exact recurring failure mode (a known type-coercion gotcha at a driver boundary,
     a specific fail-open bug class, a data path with a history of silent breakage), the way you'd
     write a postmortem action item. Generic items still apply; specific ones catch more. -->

Adversarial mandate, in priority order:

1. **Mocked vs. real.** If any test this diff relies on for its claims uses an in-memory store, a stub/fake client, or a live-but-`skip`ped test, determine whether the real path actually works — run it yourself against real infrastructure if this environment allows it, or explicitly flag in your bug report that the real path remains unverified and why. A green test against a fake is not evidence.
2. **Boundary and type-coercion bugs at integration points.** Values crossing a serialization, driver, or cast boundary (a string bound to a typed SQL parameter, a loosely-typed API payload, a timezone/locale conversion) are a common source of bugs that compile and test-pass yet fail against the real dependency. Check every new or touched boundary against its declared/expected type.
3. **Authorization / access-control fail-closed behavior.** For anything touching entitlement checks or a governed data/action path: does an unentitled request actually get denied? What happens if the policy or audit backend is unreachable — does it fail closed (deny) or fail open (allow)? Try it if you can.
4. **Audit/observability completeness.** For any action this project's own docs say must be audited or logged, verify an event actually lands in the real store — not just that the code path that should call it exists.
5. **Test reachability.** A live/skipped test never wired into the actual build/test command (or an equivalent CI-reachable path) is equivalent to no test.
6. **Injection.** Anywhere user-controlled input reaches a SQL string, shell command, or file path.
7. **Idempotency and partial failure.** Does retrying an operation duplicate side effects? Does a failure partway through leave orphaned or inconsistent state across whatever this project's control-plane/data stores are split across?

Make at most {{BREAK_ATTEMPTS}} distinct attempts to break the implementation (write/run an adversarial test, try a malicious or boundary input, check a mocked path against real infra, etc.). Stop as soon as you confirm one real break — you don't need to exhaustively enumerate every possible issue once you've found a genuine one. If none of your attempts break it within that budget, say so explicitly rather than silently skipping this section.

## Bug reports

Report any issue found above (in "What to check" or the red-team pass) as:

### Bug: <one-line title>
- **Severity**: critical | high | medium | low
- **Confirmed**: yes (you reproduced it yourself) | no (suspected, not verified)
- **Repro**: the exact command, test name, or steps that demonstrate it
- **Expected vs. actual**:

## Adjudication (you are also the coordinator here)

Before choosing your final verdict, adjudicate your own bug reports with a skeptical eye — a reviewer that treats every hunch as a blocker is as useless as one that rubber-stamps everything. Apply this policy exactly, don't override it with your own judgment:

- Any bug report marked **Confirmed: yes** at **severity high or critical** → `VERDICT: request_changes`, with that bug report included verbatim (this is what gets handed back to the author).
- Only **unconfirmed** or **low/medium severity** findings, and you're not confident enough to approve outright → `VERDICT: block_human`. Don't auto-forward a suspicion you haven't verified as if it were a confirmed defect — that's a human call, not yours to make unilaterally.
- No bugs found after a genuine red-team attempt → proceed to the normal verdict criteria below.

## Required output format

End your response with exactly one line, no other text on that line:

`VERDICT: approve` — no blocking issues, and the red-team pass found nothing confirmed.
`VERDICT: request_changes` — close, but needs a specific fix (including any confirmed high/critical bug report per the adjudication policy above). Your prose above must describe the fix precisely enough to hand to a fresh agent with no other context.
`VERDICT: block_human` — you're not confident enough to approve, you have only unconfirmed/low-severity findings, or you found something that needs a human judgment call (ambiguous spec, a real architectural tradeoff, anything touching auth/policy/data-access correctness).
