# Licensing

What license governs what in this repository, what that means if you build your own app or module
on top of it, and where the automated license scan fits. This is the *how it works* companion to
[ADR-0009](../adr/0009-open-source-license.md) (why Apache-2.0 was chosen) and
[ADR-0016](../adr/0016-automated-license-and-provenance-scanning.md) (why the scan exists). Read
this before you start a Tier 2 or Tier 3 build — see [building a study](building-a-study.md) for what
those tiers mean.

**This is background, not legal advice.** Nothing here substitutes for your own institution's
counsel, especially once you're distributing something.

## What's licensed under what

| | License | Covers |
|---|---|---|
| Code in this repository | **Apache-2.0** | `server/`, `packages/`, `apps/`, `models/`, `analysis/`, `tools/` |
| Documentation, schemas, specifications | **CC-BY-4.0** | `docs/`, `contracts/` |
| Data your own study collects | Your call | Not this repository's to license — the roadmap assumes CC-BY-4.0 for published exports as a starting point, and your IRB or institution may require something else |

Two upstream dependencies this platform leans on hardest are already permissive and compatible:
Starsim is MIT, Herald is Apache-2.0. Neither constrains what you can build.

## What Apache-2.0 asks of you

Apache-2.0 is permissive: **your Tier 2 app or Tier 3 module can be closed-source, proprietary, or
commercial.** Nothing about using Epidemica obligates you to open anything of your own.

In return, if you redistribute Epidemica's code — as-is or modified, inside your own app binary —
you must:

- keep the copyright and license notices intact,
- state prominently that you changed a file, if you changed it,
- **carry forward the `NOTICE` file's attributions.** This is the one people miss. `NOTICE` exists
  because Apache-2.0 §4(d) requires it: a "NOTICE text file... within the Derivative Works" must
  reproduce the attribution notices from any Apache-2.0 work it's built on. If your app statically
  embeds `epidemica_core` or `epidemica_proximity`, your app's own attribution file needs to carry
  what this repository's `NOTICE` already carries, plus anything you add yourself.

Apache-2.0 also grants an explicit **patent license** from every contributor for their contributions
— real protection MIT does not give you — with one condition attached: if you sue a contributor over
patent claims reading on their contribution, your license to use their contribution terminates. This
is a defensive clause, not a trap, but it is a real difference from MIT that ADR-0009 weighed
deliberately.

## If your module depends on something copyleft

Epidemica's license doesn't stop you writing a Tier 3 module against a GPL- or AGPL-licensed
library. The constraint isn't "you can't," it's **what that choice does to everything you ship it
combined with.**

The standard concern with copyleft, stated plainly: if you distribute a single binary that combines
Apache-2.0 code (Epidemica's) with GPL-licensed code (your dependency), the combined work is
generally understood to be subject to the GPL for the whole distribution — including the parts that
started out Apache-2.0. "I only used one GPL library for one feature" does not confine the obligation
to that feature once it's compiled into the same app. Static linking and tightly-coupled dynamic
linking are both commonly treated this way; the more genuinely separate two programs are — communicating
over a process or network boundary rather than sharing an address space — the stronger the argument
that they're not a combined work at all. This is exactly the reasoning behind the CIAS boundary
policy already in this codebase:

> CIAS 3.0 is GPL-3.0. Epidemica integrates with it **only across a network boundary**. No
> CIAS-derived code may enter this repository. — `NOTICE`, and [ADR-0009](../adr/0009-open-source-license.md)

If a copyleft dependency looks unavoidable for what you're building, the CIAS pattern — a separate
service, called over HTTP, never linked into your binary — is the template to copy, not a special
case.

A rough guide, not a substitute for actually reading the license you're depending on:

| Dependency's license | Bundling it into your app | What it asks of you |
|---|---|---|
| MIT, BSD-2/3-Clause, ISC, Apache-2.0 | Fine | Carry forward its attribution notice |
| LGPL | Usually fine if dynamically linked; static linking is genuinely murkier | Get real advice before static-linking an LGPL library |
| MPL-2.0 | Fine; it's file-level copyleft | Contribute back changes to *that library's own files*, nothing else |
| GPL, AGPL | Only if you're willing to distribute your whole app under GPL/AGPL | Integrate at a network boundary instead, as CIAS does |

## Attribution, in practice

`NOTICE` is maintained by hand, by whoever adds a dependency, at the point they add it. Nothing in CI
checks that it's current — the license scan (below) catches an unexpected *license*, not a missing
*attribution line* for a properly-licensed one. If you vendor a new Apache-2.0 or BSD dependency into
your own module, add its notice yourself; nothing will remind you.

## A known gap: per-file SPDX headers

ADR-0009 called for a `SPDX-License-Identifier: Apache-2.0` header in every new file, added as each
file is created. Today that's true only in `models/src` (Python). Zero of the 53 Elixir files under
`server/lib`, and zero of the 19 Dart files checked under `packages/epidemica_core/lib`, carry one.
This is a real inconsistency, not a signal that those files are unlicensed or under a different term:
**every file in this repository is Apache-2.0 by default, per the top-level `LICENSE`, header or
not.** If you're copying a file from this repository as a template for your own module, its absent
header is a gap in our practice, not a statement about that file's license.

## Building your own module with an AI coding agent

The risk [ADR-0016](../adr/0016-automated-license-and-provenance-scanning.md) describes for this
repository is not specific to this repository: a coding agent can reproduce a distinctive,
non-trivial snippet from its training data, and some of that training data is GPL- or
AGPL-licensed. Once your Tier 3 module leaves this repository, that risk is yours to manage, not
ours.

`tools/license-scan.sh` and `tools/check-license-scan.py` are not Epidemica-specific — point them at
your own module's source the same way this repository points them at its own (see
[`tools/README.md`](../../tools/README.md) for the exact commands and, importantly, the pitfall
about batching multiple sibling paths in one ScanCode invocation, which will silently sweep in your
own vendored dependencies if you get it wrong the way this repository initially did). The same
cadence recommendation applies: not before every commit, but before a release, and before opening a
pull request that came out of a long agent-assisted session touching many files at once.

### Evidencing your own human authorship

The scan above addresses whether your code infringes someone else's copyright. A separate question —
whether *you* can claim authorship over what an agent helped you write — turns on a different kind of
evidence: the US Copyright Office's stated position is that a work needs meaningful human creative
control, not mere prompting, to support a copyright claim, and the record that demonstrates that
control is the back-and-forth itself — direction given, alternatives rejected, output reviewed and
revised — not the final diff alone.

`tools/render-transcript.py` renders a coding session's raw log into readable Markdown for exactly
this purpose: every message from both sides in full, so the human direction and review is legible
without wading through megabytes of tool call scrollback. It is not specific to this repository
either — point it at any session log from any project. See [`tools/README.md`](../../tools/README.md)
for how to find the raw log and how to render just a time range. As with the license scan: this
produces a record, not a legal opinion, and rendering a transcript doesn't make anything
copyrightable by itself — it only preserves the evidence, for whoever eventually has to make that
argument, that the evidence existed.

## See also

- [ADR-0009](../adr/0009-open-source-license.md) — why Apache-2.0, and the alternatives weighed
- [ADR-0016](../adr/0016-automated-license-and-provenance-scanning.md) — why the scan exists and its
  limits
- [`tools/README.md`](../../tools/README.md) — how to run the scan, and when
- [Building a study](building-a-study.md) — the tier system this document assumes
- `NOTICE` and `LICENSE` at the repository root
