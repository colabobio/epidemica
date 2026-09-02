# ADR-0009: Open-source license selection

- **Status:** **Accepted** — Apache-2.0
- **Date:** 2026-09-02
- **Deciders:** Colubri (PI)

## Context

The CAREER proposal states that Epidemica will be released under the MIT License, but the choice has
not actually been made. It needs to be, early, for four reasons:

1. **It gates contributors.** Every commit accepted before the license is set is code whose terms
   may later need renegotiating with its author.
2. **It constrains the CIAS integration.** CIAS 3.0 is **GPL-3.0**. If Epidemica is permissively
   licensed, integration must stay strictly at the network boundary — no CIAS-derived code in this
   repository, ever. If Epidemica were GPL-3.0, code-level integration becomes possible but
   closed-source study apps become impossible.
3. **It constrains adopters.** Some university and industry partners cannot ship copyleft code in an
   app they distribute. Others actively prefer copyleft.
4. **Key dependencies are already fixed:** Starsim is **MIT**, Herald is **Apache-2.0**. Both are
   compatible with any option below, but Apache-2.0 code cannot be absorbed into GPL-2.0-only work.

## Decision

Epidemica code is licensed under **Apache-2.0**. Documentation, schemas and specifications are
licensed under **CC-BY-4.0**.

| License | Effect | Fits if… |
|---|---|---|
| MIT | Maximum adoption, minimal friction. No patent grant. | Optimising purely for uptake. Matches Starsim. |
| **Apache-2.0** — *chosen* | Permissive **plus an explicit patent grant** and contributor terms. | Permissive *and* some protection around novel methods. Matches Herald. |
| BSD-3-Clause | Permissive, common in academic infrastructure. | Institutional preference; no patent grant. |
| MPL-2.0 | File-level copyleft; combinable with proprietary code. | Want fixes contributed back without blocking closed-source apps. |
| GPL-3.0 | Strong copyleft; enables code-level CIAS integration. | Willing to forbid closed-source study apps. |
| AGPL-3.0 | Adds the network clause; guards against SaaS capture. | Fear commercial hosting without contribution. Blocks much institutional adoption. |

Rationale for Apache-2.0: it permits closed-source study apps (which some IRBs and industry partners
require), it carries a patent grant that matters given the distance-estimation and proximity work, it
is compatible with both Starsim's MIT and Herald's Apache-2.0, and it is one-way compatible with
GPL-3.0 should a code-level CIAS combination ever become desirable in that direction.

## Consequences

**Positive.** Broad adoption, including by groups that cannot use copyleft. Explicit patent grant.
No license-compatibility friction with the two most important upstream dependencies. Clear, standard
contributor terms.

**Negative.** A vendor could host or embed Epidemica commercially without contributing anything
back; if that outcome is unacceptable, AGPL-3.0 is the only real defence and we should choose it
knowingly rather than discover the preference later. Apache-2.0 headers and `NOTICE` file
maintenance are a small ongoing chore. It permanently forecloses absorbing GPL code — including
CIAS — into this repository.

**Neutral.** Data and dataset licensing is a separate question; the roadmap assumes CC-BY-4.0 for
study exports, which each IRB may override.

## Alternatives considered

Covered in the table above. The genuinely live alternatives were **MIT** (if the patent grant were
judged unnecessary and matching Starsim were worth more) and **AGPL-3.0** (if protecting against
commercial capture outweighed institutional adoption). MPL-2.0 was a defensible middle path if
contribution-back mattered but closed-source apps had to remain possible. Apache-2.0 was chosen for
the patent grant and for compatibility with both key upstreams.

## Open questions

None block this decision. Two items remain as due diligence:

- **Copyright holder line.** `NOTICE` currently reads *"University of Massachusetts Chan Medical
  School and the Epidemica Project Contributors"*. Confirm with UMass Chan technology transfer that
  the institution is the correct holder for employee-created work, and that there is no pre-existing
  IP claim over the distance-estimation or OO-derived gamification code. Adjust `NOTICE` if needed —
  this does not affect the license choice.
- **Provenance of Herald-derived native sources.** Confirm the Swift/Kotlin in `epigames-app` is the
  lab's own code calling Herald's API, rather than copied Herald source. Either is fine under
  Apache-2.0, but copied source needs its notices preserved in `NOTICE`.

## Consequent actions

- [x] Add `LICENSE` (canonical Apache-2.0 text) and `NOTICE`.
- [ ] Add per-file `SPDX-License-Identifier: Apache-2.0` headers — do this as each file is created,
      not as a retrofit sweep later.
- [ ] Add a CI dependency-license allow-list check (allow: Apache-2.0, MIT, BSD-2/3, ISC, CC-BY-4.0;
      flag: MPL, LGPL; reject: GPL, AGPL, and anything unlicensed).
- [ ] **Decide DCO sign-off vs. CLA** before the first outside pull request. Recommendation: **DCO**
      — a one-line `Signed-off-by` trailer, no paperwork, no institutional agreement to negotiate, and
      standard practice for research infrastructure. A CLA would be warranted only if relicensing
      later is a realistic need.
- [ ] State the CIAS boundary policy explicitly in the connectors ADR: network boundary only, no
      vendored or derived CIAS code, enforced by the CI license check.

## Validation

Not applicable — this is a policy decision, not an empirical one. External contributions may now be
accepted, subject to the DCO/CLA item above.
