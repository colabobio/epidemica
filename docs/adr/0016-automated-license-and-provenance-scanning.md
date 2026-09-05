# ADR-0016: Automated license and provenance scanning

- **Status:** Accepted
- **Date:** 2026-09-05
- **Deciders:** Colubri (PI)
- **Supersedes / Superseded by:** —

## Context

ADR-0009 chose Apache-2.0 and, in its own consequent-actions checklist, named a CI dependency-license
allow-list as outstanding work. It never shipped: there is no `.github/` directory in this repository
before this ADR, and nothing enforces the license choice beyond the `LICENSE`/`NOTICE` files and the
discipline of whoever is writing code that day.

That gap matters more with an AI coding agent in the loop than it did before. A model trained on
public code can reproduce a distinctive, non-trivial snippet from its training data, and some of that
training data is GPL- or AGPL-licensed. If such a snippet lands in this repository and ships under
Apache-2.0, two separate problems follow: the snippet's actual copyright holder was never granted
permission under Apache-2.0 terms, and — if the snippet came from a copyleft project — the license
obligations that snippet actually carries (attribution, source disclosure, same-license redistribution)
were never honoured. Neither problem is specific to AI assistance; a human copying a Stack Overflow
answer or a GitHub gist has always been able to cause it. What is new is that it can happen at the
volume and speed an agent works at, without either party necessarily noticing.

**What this is not new evidence for.** The US Copyright Office's position that a purely AI-generated
work lacks the human authorship needed for copyright registration is a separate question from
whether a given snippet infringes someone else's copyright. Even code this project could not itself
register a copyright in could still, if it reproduces someone else's protected expression, expose
this project to an infringement claim and a license-compliance obligation. Automated scanning
addresses the second problem. It has no bearing on the first, and this ADR takes no position on it.

## Decision

We will run **ScanCode Toolkit** (Apache-2.0, `nexB/scancode-toolkit`) against the repository's own
source — never against vendored dependency trees — on every push and pull request, applying an
allow-list derived directly from ADR-0009: Apache-2.0, MIT, BSD-2/3-Clause, ISC, and CC-BY-4.0 (for
docs/schemas) pass; any GPL/AGPL/LGPL match in project source fails the build; anything else is
printed for a human to look at and does not block.

For how to run this locally, when to bother doing so outside of CI, and what each step of the
GitHub Action does, see [`tools/README.md`](../../tools/README.md) — this ADR is the why, that file
is the how. For what this means if you're building your own app or module on top of Epidemica,
see [Licensing](../concepts/licensing.md).

### Why ScanCode, and not a broader "clone detection" tool

ScanCode does one thing well: it matches file contents against a large, current database of known
license *text* (the SPDX list plus its own curated rules) and extracts copyright statements. That is
exactly the check this repository was missing, it is free and open source, and it installed and ran
cleanly under this project's own Python 3.13 toolchain with no compatibility work.

It is not a tool that can tell us "this function resembles a function in some GPL project on GitHub."
No open-source tool does this well at web scale. Commercial Software Composition Analysis products
(Black Duck, FOSSA, Snyk) advertise snippet-matching against their own curated databases of known
open-source code, which is a genuinely different and more expensive capability than license-text
detection — and even those do not claim coverage of "all code that has ever been published." We are
not adopting one of them now; ScanCode's license-text detection is the highest-value check available
at zero cost, and closing ADR-0009's outstanding item with it is better than continuing to have
nothing.

### An operational trap worth recording, because it cost real debugging time

**ScanCode computes a common ancestor across every path given in a single invocation and walks the
whole thing.** Passing `models/src` and `analysis/src` to one `scancode` call does not scan those two
directories — it scans their common ancestor, which in this repository is the root, which is every
`.venv`, every `deps/`, and several gigabytes of vendored third-party code, none of which this check
has any business evaluating (those dependencies are already reviewed and pinned; see the CIAS
boundary policy this ADR reaffirms below). A `--ignore` glob does not reliably prevent this. The only
verified-correct fix is `tools/license-scan.sh`'s actual approach: one ScanCode invocation per
top-level project path, merged afterward. Do not "simplify" this back to a single batched call without
re-verifying against a fresh `.venv` — this was reproduced twice before the cause was found.

### Worked example, from the first real run

The first scan against this repository's actual source correctly flagged two files:
`models/pyproject.toml` and `analysis/pyproject.toml`, both matched as `gpl-3.0-plus`. On inspection,
both matches are a code comment explaining why the `rfc3987` package — GPLv3+ — was excluded from the
dependency list, exactly the exclusion ADR-0009's own checklist called for. This is the tool working
as intended: it does not know a comment from a license header, so it reports both, and a human
confirms which is which. It also, correctly, ignored `NOTICE`'s and this repository's own `README.md`'s
mentions of GPL-3.0 and AGPL-3.0 (in the CIAS boundary policy and the license-comparison table
respectively) because those paths are explicitly excluded from the check — the point of naming a
license in a policy document is to talk about it, not to avoid the word.

## Consequences

**Positive.** ADR-0009's outstanding CI item is closed. A GPL/AGPL license header or SPDX identifier
landing in project source — from any source, human or agent — now fails a build instead of merging
silently. The check is free, runs in under a minute once ScanCode's index is warm, and requires no
new infrastructure beyond GitHub Actions.

**Negative.** This is a text-matching check and nothing more. It will not catch a function that was
copied and then renamed, reformatted, or lightly paraphrased — which is a realistic way for an LLM to
reproduce training data, since it rarely reproduces a file byte-for-byte. It also cannot bound false
negatives: "no known license text found" is not "definitely not derived from someone else's work," and
this ADR does not claim otherwise. `unknown`/`unknown-license-reference` matches are common noise
(a comment saying "not GPL-compatible" trips a keyword match) and need a human's five minutes, not an
automatic gate — encoding a hard block on every low-confidence match would train people to ignore the
report entirely, which is worse than not having it.

**Neutral.** This does not change what license Epidemica ships under (Apache-2.0, per ADR-0009); it
only checks that the choice is being honoured.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Do nothing beyond code review discipline | Was the status quo; ADR-0009 already flagged it as a gap, and an agent-assisted codebase raises the stakes of leaving it unaddressed. |
| Commercial SCA with snippet-matching (Black Duck, FOSSA, Snyk) | Real capability gain over ScanCode for detecting *rewritten* code, but a cost and a vendor relationship this project is not ready to take on for a first pass. Worth revisiting if ScanCode's blind spot proves costly in practice. |
| Block every non-allow-listed match, including `unknown`/low-confidence ones | Produces enough noise that people learn to ignore or bypass the check; see Negative consequences above. |
| Manual, ad hoc searches of distinctive lines via GitHub code search before merging suspicious-looking diffs | Still worth doing for anything that looks unusually polished or references unrelated domain terms — this is a spot-check, not a substitute for a repeatable, automated gate, and the two are complementary rather than either-or. |

## Open questions

- Whether to add a targeted, best-effort check for verbatim-string reuse (searching a handful of
  distinctive tokens from a diff against public code search) as a second layer. Not adopted now for
  lack of a reliable, free API to run it against at CI speed; worth revisiting.
- Whether the coding agents used on this project expose a "public code match" filter (as some
  commercial coding-agent products do) that could be enabled as a first line of defence before code
  ever reaches a diff. Not evaluated as part of this ADR.
- University technology-transfer/IP counsel involvement before any wider public release remains a
  recommendation, not a requirement this ADR can discharge — see ADR-0009's own open questions, which
  this ADR does not resolve.

## Validation

The check is validated by construction against its own first run (see the worked example above): it
correctly flagged two comments referencing an excluded GPL dependency and correctly ignored this
repository's own policy documents. It will be considered wrong, and need revisiting, if it either (a)
produces enough false positives in ordinary development that people start merging with `[skip ci]`, or
(b) a real copyleft-derived snippet is later discovered in the repository that this check had already
run against and passed.
