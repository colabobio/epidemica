# tools

Scripts that support development but are not part of any shipped runtime. Two things live here: the
license scan described in [ADR-0016](../docs/adr/0016-automated-license-and-provenance-scanning.md),
and a transcript renderer for evidencing human authorship (below).

If you're building your own app or module on Epidemica rather than working in this repository, read
[Licensing](../docs/concepts/licensing.md) first — it explains what these scripts protect against
and why the same tooling is worth pointing at your own module's source too.

## License scan

Checks the repository's own source for embedded license text or SPDX identifiers that do not belong
in an Apache-2.0 project — most importantly, anything from the GPL/AGPL/LGPL family, which would mean
a snippet (human- or agent-written) was pulled in from a copyleft-licensed source without anyone
noticing. It is a text-matching check against known license text, not a guarantee of non-infringement
— read ADR-0016 before trusting a clean run more than that. Run it by hand; it is deliberately not a
CI job — see [ADR-0017](../docs/adr/0017-manual-license-scan-not-ci.md) for why.

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

### When to run it

There is no CI job for this — see [ADR-0017](../docs/adr/0017-manual-license-scan-not-ci.md). It was
tried on every push and pull request and removed after a real run took over five minutes and failed a
merge on a confirmed false positive, holding up outgoing changes for over an hour before the failure
was traced back to something already known to be benign. Running this is a manual step for now, which
means it only catches something if someone actually runs it. Run it:

- **Before opening a pull request that adds a new third-party dependency**, or that came out of a
  long agent-assisted session touching many files in one sitting — exactly the situation ADR-0016 was
  written for, and worth checking before the diff is large enough that a REJECT is tedious to trace
  back to one line.
- **Before tagging a release**, as a final sweep, the same way `mix format --check-formatted` and
  `flutter analyze` get run before calling something done.
- **Whenever a change touches `pyproject.toml`, `mix.exs`, or `pubspec.yaml`** — the actual dependency
  manifests, which is where a real license problem would show up.

A failing run means: open `check-license-scan.py`'s output for the flagged file and line, decide
whether it's a real problem or a false positive (comment mentioning a license, test fixture data,
etc.), and either remove the offending code or — if it's a confirmed false positive — fix it at the
source the way ADR-0017 did: reword the comment so it doesn't read as license text to a text matcher,
rather than adding the file to `check-license-scan.py`'s `EXCLUDED_PREFIXES`, which would blind the
check exactly where a real problem is most likely to appear. Don't silence a REJECT by loosening the
copyleft check itself; that defeats the one thing this tool exists to catch.

## Transcript renderer

`tools/render-transcript.py` turns a Copilot session's raw `.jsonl` log into a readable Markdown
transcript: every message from both sides in full, tool calls reduced to one line each so the record
reads as the reasoning rather than the scrollback.

### Why you'd want this

A rendered transcript is a record of the human direction, review, and iterative refinement behind an
AI-assisted change — the kind of evidence copyright authorities look at when assessing whether a
work has the human authorship needed for protection. See
[Licensing](../docs/concepts/licensing.md) for the fuller reasoning and its limits: **this script
produces a record, not a legal opinion, and rendering a transcript doesn't make anything copyrightable
by itself.** Keep transcripts for changes you'd want to be able to show your own creative control
over later — this repository does not keep them checked in for every session, since the raw logs are
many megabytes each; render one when you actually want the artifact.

### Finding the raw log

VS Code Copilot Chat writes one `.jsonl` per session under your workspace storage, typically:

```
~/Library/Application Support/Code/User/workspaceStorage/<workspace-hash>/GitHub.copilot-chat/transcripts/<session-id>.jsonl
```

(Linux/Windows equivalents live under the platform's own `Code/User/workspaceStorage/`.) The exact
session id is shown in the chat view's session picker.

### Running it

```bash
python3 tools/render-transcript.py <session.jsonl> <out.md>
```

To render only part of a session — the work done in one sitting, or the exchanges relevant to one
feature — use `--since`/`--until` with an ISO-8601 timestamp (date-only is fine; a bare date or time
with no timezone is treated as UTC, matching how the log itself timestamps everything):

```bash
python3 tools/render-transcript.py <session.jsonl> <out.md> --since 2026-09-05 --until 2026-09-06
python3 tools/render-transcript.py <session.jsonl> <out.md> --since 2026-09-05T09:00:00Z
```

Both bounds are inclusive. Either can be omitted to leave that end of the range open. The rendered
file's header always states the *full* session's span alongside the range actually rendered, so a
trimmed transcript still says what it was trimmed from.

### A schema note worth knowing before you trust the output

The event schema this script reads is VS Code Copilot Chat's own internal log format, not a stable
public API — it has already changed once. An earlier version of this script looked for `error`/
`errorMessage` fields on a failed tool call; the actual field, confirmed against a real transcript, is
a plain `success: false` with no error text at all. If a future Copilot Chat release changes the
schema again, the symptom will be the same as last time: the script keeps running and produces
plausible-looking output that silently drops information (here, which tool calls failed) rather than
erroring. Spot-check a render against the raw `.jsonl` after a VS Code Copilot Chat update before
trusting it for something that matters.
