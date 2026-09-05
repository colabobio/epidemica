# ADR-0017: Run the license scan manually, not automatically in CI

- **Status:** Accepted
- **Date:** 2026-09-05
- **Deciders:** Colubri (PI)
- **Supersedes / Superseded by:** Supersedes the CI-triggering clause of [ADR-0016](0016-automated-license-and-provenance-scanning.md); everything else in that ADR — the scan, its allow-list, its scope and limits — is unaffected and still the recommended tool.

## Context

ADR-0016 wired the license scan into GitHub Actions on every push and pull request. On its first
real run against a normal change, the job took over five minutes and then failed a merge — on the
exact false positive ADR-0016's own worked example had already diagnosed as benign:
`models/pyproject.toml` and `analysis/pyproject.toml` each carry a comment explaining why the
`rfc3987` package was excluded for being copyleft-licensed, and the comment's own mention of the
license name matched the license-text detector it was describing. The failure held up outgoing
changes for over an hour before anyone connected it to the already-documented case.

Two costs compound here, not one. ScanCode's license-index warm-up plus scanning even a
project-source-only tree is not fast — several minutes, observed directly, not estimated. And gating
every commit on a signal that was *already known* to be a false positive before the workflow ever ran
is a worse version of the failure mode ADR-0016's own "Negative consequences" section warned against
for genuinely low-confidence matches: blocking on a confirmed non-issue teaches people to route around
the check, which is strictly worse than not having it.

## Decision

We will remove the scan from CI and run it manually instead, at the cadence already documented in
[`tools/README.md`](../../tools/README.md) — before a release, before a pull request that adds a
dependency or came out of a long agent-assisted session, or when investigating a specific concern.
The scan itself, its allow-list, and its scope are unchanged; only *when* it runs changes.

`.github/workflows/license-scan.yml` is deleted rather than left in place but disabled, on the
grounds that a present-but-inactive workflow file invites exactly the question "does this actually
run?" that a missing file does not, and restoring it later is a small, git-tracked diff if this
decision is revisited.

Separately, and regardless of the CI question: the `rfc3987` exclusion comments in both
`pyproject.toml` files are reworded to describe the excluded license as "copyleft-licensed" rather
than naming the SPDX expression `GPLv3+` directly. Confirmed against ScanCode directly: the reworded
text produces no license match at all, while the original triggered a 100%-confidence `gpl-3.0-plus`
match. The comment says the same thing to a human either way; only its legibility to a text-matching
tool changes. This was worth fixing on its own, independent of whether the scan runs in CI or by
hand — a false positive that recurs on every manual invocation is exactly as much of a
cry-wolf problem as one that recurs on every push.

## Consequences

**Positive.** Nothing blocks a merge on a multi-minute job, or on a match already known to be benign.
The tool remains fully available and documented for anyone who wants to run it, and now does so
without immediately reproducing the false positive that prompted this ADR.

**Negative.** Nothing catches a genuine copyleft inclusion automatically before merge; catching one
now depends on someone actually running the scan. This is a real reduction in coverage, accepted
deliberately rather than by neglect — see Open questions.

**Neutral.** The scan itself, its allow-list (ADR-0016), and the worked example it was validated
against are unchanged.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Keep it in CI; add the two flagged files to `check-license-scan.py`'s `EXCLUDED_PREFIXES` | Blinds the check exactly where a real dependency-license problem would actually show up — a `pyproject.toml` is the one place this matters most, more than `NOTICE` or `LICENSE` ever will. |
| Keep it in CI; only reword the comments | Fixes the specific false positive but not the 5+ minute runtime, which is the larger cost and the reason this was disruptive rather than merely annoying. |
| Move it to a scheduled (nightly/weekly) CI run instead of per-push | Blocks nothing per-commit and would have avoided this specific incident, but adds infrastructure and a monitoring burden for a check this project has not yet run often enough to justify. Worth revisiting if manual cadence proves not to happen in practice. |

## Open questions

Whether the manual cadence in `tools/README.md` is actually followed without a CI backstop is
unverified — the honest risk this ADR accepts. If license-scan hygiene turns out to matter enough in
practice that this is a problem, the next step is a scheduled (not per-push) CI run, not a return to
blocking every commit.

## Validation

This will be judged wrong if a real copyleft inclusion ships because nobody ran the scan before
merging it. If that happens, the fix is a scheduled job, not reverting to gating every push — the
runtime cost that motivated this ADR does not go away just because the failure this time was a false
positive.
