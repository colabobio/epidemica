# tools

Scripts that support development but are not part of any shipped runtime. Currently one thing
lives here: the license scan described in
[ADR-0016](../docs/adr/0016-automated-license-and-provenance-scanning.md).

If you're building your own app or module on Epidemica rather than working in this repository, read
[Licensing](../docs/concepts/licensing.md) first — it explains what these scripts protect against
and why the same tooling is worth pointing at your own module's source too.

## License scan

Checks the repository's own source for embedded license text or SPDX identifiers that do not belong
in an Apache-2.0 project — most importantly, anything from the GPL/AGPL/LGPL family, which would mean
a snippet (human- or agent-written) was pulled in from a copyleft-licensed source without anyone
noticing. It is a text-matching check against known license text, not a guarantee of non-infringement
— read ADR-0016 before trusting a clean run more than that.

### One-time setup

```bash
python3 -m venv .venv-license-scan
source .venv-license-scan/bin/activate
pip install -r tools/requirements-license-scan.txt
```

The version in `requirements-license-scan.txt` is pinned to what was actually tested against this
repository. Don't casually bump it — a newer ScanCode release can change match behaviour, and the
worked example in ADR-0016 was validated against this exact version.

### Running it

```bash
bash tools/license-scan.sh /tmp/license-scan.json
python3 tools/check-license-scan.py /tmp/license-scan.json
```

The first command scans; it takes a couple of minutes the first time a fresh install runs it (ScanCode
builds its license index), seconds after that. The second applies the allow-list and exits non-zero
only on a REJECT — see below.

### Reading the output

- **REJECT** — a GPL/AGPL/LGPL match in project source. This is what fails the run (exit code 1).
  Before touching the flagged code: open the file at the reported line and confirm whether it is
  actually copyleft text, or — as happened the first time this ran — a comment *documenting* why a
  GPL-licensed package was excluded, which is the correct, intended thing to find there.
- **REVIEW** — a match ScanCode found but that isn't on the allow-list and isn't copyleft either
  (commonly `unknown`/`unknown-license-reference`, which is often just a comment containing a license
  *keyword*, not actual license text). Printed for a human to glance at. Does not fail the run —
  see ADR-0016's Negative consequences for why blocking on every low-confidence match would be worse
  than not checking at all.
- **Clean** — no copyleft text found. Not the same claim as "definitely not derived from anything";
  see ADR-0016's limitations.

### When to run it locally

CI (below) already runs this on every push and every pull request — routine local runs before each
commit add friction without adding coverage, since a single commit rarely changes the verdict and the
push will be checked anyway. Run it locally when:

- **A CI license-scan job has failed** and you want to iterate on the fix faster than round-tripping
  through Actions each time.
- **You are about to open a pull request that adds a new third-party dependency**, or that came out of
  a long agent-assisted session touching many files in one sitting — exactly the situation ADR-0016
  was written for, and worth checking before the diff is large enough that a REJECT is tedious to
  trace back to one line.
- **Before tagging a release**, as a final sweep, the same way `mix format --check-formatted` and
  `flutter analyze` get run before calling something done.

There's no benefit to a fixed periodic schedule ("once a week") independent of these — the check is
cheap enough to run exactly when one of the above is true, and CI already covers everything else.

## The GitHub Action

[`.github/workflows/license-scan.yml`](../.github/workflows/license-scan.yml) runs the same two
commands above on a clean GitHub-hosted runner, on every push to `main` and on every pull request.

What each step does:

1. **Checkout + install Python 3.13** — matches the version this was validated against.
2. **Install ScanCode Toolkit** from the pinned `requirements-license-scan.txt`, so CI and a local run
   use the identical version.
3. **Run license scan** — `tools/license-scan.sh`, writing its JSON report to the job's temp directory
   rather than `/tmp` on a developer's machine, since a CI runner is disposable and shouldn't leave
   anything behind.
4. **Apply allow-list** — `tools/check-license-scan.py` against that report. This step's exit code is
   what makes the job pass or fail: red X means a REJECT was found (see above), not that ScanCode
   itself errored.
5. **Upload full report** — runs `if: always()`, so the complete JSON is attached as a build artifact
   even when the job fails, or when the human-readable summary in the log truncates a long finding
   list. Find it under the workflow run's **Summary** tab, in the **Artifacts** section, named
   `license-scan-report`.

A failing job means: open the **Apply allow-list** step's log for the flagged file and line, decide
whether it's a real problem or a false positive (comment mentioning a license, test fixture data,
etc.), and either remove the offending code or — if it's a confirmed false positive like the
`pyproject.toml` case in ADR-0016 — extend `check-license-scan.py`'s `EXCLUDED_PREFIXES` with a
one-line comment explaining why, the same way `NOTICE` and `LICENSE` are excluded today. Don't silence
a REJECT by loosening the copyleft check itself; that defeats the one thing this tool exists to catch.
