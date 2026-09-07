# AI-assisted coding

This repository, its client packages, its transmission model, and a good share of its documentation
were built substantially with AI coding agents. This document is the practical background for
anyone using one here, or building their own Epidemica app or module with one: what "AI-assisted
coding" means concretely, what current accepted practice looks like, and what this platform
specifically asks of you given that it handles health-adjacent research data.

**This is background and practice, not policy.** Your own institution's AI-use policy, IRB protocol,
and data-governance rules take precedence over anything here — see the note on data at the end.

## What this means concretely

An AI *coding agent*, in the sense this document uses, is different from autocomplete: it reads and
writes files, runs shell commands, searches the codebase, and iterates on its own output across many
steps with limited human intervention per step. That's what makes [`AGENTS.md`](../../AGENTS.md),
[`CLAUDE.md`](../../CLAUDE.md), the nested `AGENTS.md` files, and `.claude/skills/` necessary in the
first place: an agent with that much autonomy needs the hard-won, non-obvious rules of this codebase
stated somewhere it's specified to read, or it will re-learn them by breaking something, the same way
a new human contributor would — except faster, and at the volume an agent works at.

## Accepted practice, as it currently stands

**Disclosure is converging on "normal," not "confess and apologize."** Early norms (arXiv's 2023
statement, bioRxiv's disclosure requirement) treated AI involvement as something to flag and justify.
Newer venues built specifically for AI-assisted work — GenRxiv is one — start from the opposite
premise: AI involvement is the default case for the venue, not an exception. Where this platform's
own documentation was AI-assisted, it says so plainly rather than either hiding it or hedging it.

**Machine-readable convention files are a real, converging practice, not an Epidemica idiosyncrasy.**
`AGENTS.md` is a vendor-neutral convention read by multiple coding-agent tools; `CLAUDE.md` and Agent
Skills are Claude Code's own related conventions. All exist for the same reason: an agent that has to
rediscover a codebase's traps by trial and error is expensive in a way a documented trap is not.

**Verification is a process, not a vigilance exercise.** An agent's fluency is not correlated with
its correctness — confidently wrong output reads the same as confidently right output. The accepted
mitigation is the same one good engineering already required (automated tests, code review) applied
without exception, because skipping it costs more with an agent than it ever did with a human: a
teeth-check (write the test, re-introduce the actual defect, confirm the test fails, restore) is this
repository's answer, and it exists precisely because a test that has never seen the bug proves
nothing about whether it would catch it again.

**Provenance is two separate concerns, and this repository has tooling for both.** Whether your code
infringes someone else's copyright, and whether you can claim human authorship over your own output,
are different questions with different evidence — see [Licensing](licensing.md) for the first and its
"Evidencing your own human authorship" section for the second. `tools/license-scan.sh` addresses one;
`tools/render-transcript.py` addresses the other.

**Tool-using agents are a security surface, not just a productivity one.** An agent that fetches web
pages, reads files, or runs commands can encounter content — a web page, a file, a tool's output —
that was crafted to look like an instruction. Treating fetched or generated content as *data*, never
as instructions to follow, is the accepted mitigation (this is what the OWASP Top 10 for LLM
applications names prompt injection for). Least-privilege tool access and requiring explicit
confirmation before irreversible actions are the other two legs of the same practice.

## Specific recommendations for working on Epidemica

**Read the convention files before acting, and update them when you learn something new.** Every
`AGENTS.md` in this repository — root and nested — exists because a real defect cost real debugging
time. If you find a new one working here, add it; that's the entire point of the convention, not an
optional courtesy.

**Verify before claiming done.** Run the `verify-all` skill (or the six-suite sweep it wraps) before
saying a change works, and teeth-check any regression test you write for a bug fix. See the
`verify-all` and `teeth-check` skills under [`.claude/skills/`](../../.claude/skills/).

**A contract is not done until its fixtures are.** The self-discovering test harness in
`analysis/tests/test_contracts.py`, not code review alone, is what actually enforces that every schema
has valid and invalid examples. An agent (or a human) adding a contract without fixtures will pass a
casual review and fail this check — let it fail, don't relax it.

**Scan before merging anything that adds a dependency or spans a long session.** See
[Licensing](licensing.md) and [`tools/README.md`](../../tools/README.md) for when and how. This
applies to your own Tier 2/3 module too, not only to this repository.

**Render a transcript for contributions you might need to defend authorship over later.** See
[Licensing § Evidencing your own human authorship](licensing.md#evidencing-your-own-human-authorship).
Not every session needs one; a substantial feature, or anything you'd want to point to as evidence of
your own creative direction, does.

**Give agent-proposed epidemiological or scoring changes more scrutiny than the test suite alone.**
This platform has already shipped bugs where an agent's (and a human's) confident output looked
correct and was measurably not: a time-scaled Starsim parameter 365× off that printed an identical
representation either way, and a carry-over calculation that used today's protection state to judge
an earlier day. Both passed a casual read. Neither would have passed a teeth-check against the actual
failure — which is exactly why that discipline exists here, and why it matters more for transmission
parameters and participant scoring than for most other code in this repository.

**Don't let an agent invent a default for a missing measurement.** The platform's own rule — never
synthesise what the server was supposed to compute, render nothing rather than a guess — applies just
as much to what an agent proposes as a parameter value or a fallback. An invented plausible number is
harder to catch later than an honest error.

**Treat irreversible operations as needing a human's explicit go-ahead, not an agent's initiative.** A
settled twin tick is immutable; recovering from a wrongly-run one means discarding the whole study run
via `mix epidemica.reset_study`. Running a tick, a reset, or anything else in that category should be
a step a human decided to take, not one an agent took on its own judgement mid-task.

**Never put real participant data, or anything IRB-governed, into a general-purpose agent's context.**
The observation envelope's pseudonymisation exists so that a *stored dataset* can be handled safely —
it says nothing about whether a raw export, a database dump, or a support request containing real
observations is safe to paste into an agent's context window, and it generally is not. Use the
contract fixtures or a debug study's synthetic data ([`studies/epigame-debug`](../../studies/epigame-debug))
for anything you'd otherwise reach for real data to test against.

## If you're building your own module or app with an agent

Everything above generalises past this repository. Write your own `AGENTS.md`-equivalent for the
pitfalls you discover in your own module; run the same license scan against your own source, not
just this repository's (see [Licensing](licensing.md)); keep your own transcripts for contributions
that matter; and apply the same "no real participant data in an agent's context" rule to whatever
your own study collects, whether or not it looks like Epidemica's envelope.

## What this is not

Not your institution's AI-use policy, not IRB guidance, and not legal advice — where any of those
exist and say something different, they govern, not this document.

## See also

- [`AGENTS.md`](../../AGENTS.md), [`CLAUDE.md`](../../CLAUDE.md), [`.claude/skills/`](../../.claude/skills/)
  — the conventions this document assumes
- [Licensing](licensing.md) — copyright infringement risk and evidencing human authorship, in depth
- [ADR-0016](../adr/0016-automated-license-and-provenance-scanning.md) — why the license scan exists
- [`tools/README.md`](../../tools/README.md) — how to run the scan and the transcript renderer
