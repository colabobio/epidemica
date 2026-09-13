# tools

Scripts that support development but are not part of any shipped runtime. The two main groups are:

1. the provenance and dependency-license audit described in [ADR-0016](../docs/adr/0016-automated-license-and-provenance-scanning.md), and
2. the transcript renderer for evidencing human authorship.

If you're building your own app or module on Epidemica rather than working in this repository, read
[Licensing](../docs/concepts/licensing.md) first. It explains what these checks protect against, what
they cannot prove, and why the same tooling is worth pointing at your own source too.

## Provenance and dependency-license audit

The release audit is intentionally layered. No single scanner answers all of the questions that matter
for an Apache-2.0 release, especially in an AI-assisted codebase.

The pipeline checks three different things:

| Stage | Tooling | Question it answers |
| --- | --- | --- |
| 1 | ScanCode Toolkit | Does first-party source contain embedded foreign license text, SPDX identifiers, or copyright notices? |
| 2 | SCANOSS | Does first-party source resemble known open-source files or snippets, including copyleft-licensed code? |
| 3 | ORT Analyzer + Pub license lookup | What third-party packages do we depend on, including transitive dependencies, and what licenses do they declare or publish? |

The first two stages address source provenance. The third is ordinary dependency-license due diligence
that would still matter even if no AI tools had been used.

A clean run is evidence of a reasonable automated review process; it is **not** a legal opinion and it
cannot prove that every line was independently authored.

### Why the checks are separate

`license-scan.sh` deliberately scans Epidemica's own source rather than vendored dependencies or build
artifacts. ScanCode is good at finding license text and copyright notices, but it cannot answer whether
a function with no license header resembles code from another project.

SCANOSS complements that by fingerprinting first-party source and looking for whole-file or snippet
matches in its open-source knowledge base. A SCANOSS match is a provenance lead, not proof that code
was copied from the repository it happened to match. Framework-generated files and common boilerplate
can legitimately match downstream copyleft projects, so suspicious matches require manual review.

ORT is used only as a dependency analyzer here. It resolves the Pub and Mix dependency graphs and
records package metadata. We intentionally do **not** run ORT's full dependency-source scanner in the
normal release pipeline: downloading every dependency repository and running ScanCode over all of it
adds substantial complexity and is not necessary for the primary release question. For Pub packages,
whose ORT metadata often lacks license declarations, `lookup-pub-licenses.py` downloads the exact
resolved package artifact, verifies its SHA-256 when available, extracts only root license files, and
runs ScanCode on those files.

### One-time setup

Create the dedicated ScanCode / SCANOSS environment:

```bash
python3 -m venv .venv-license-scan
source .venv-license-scan/bin/activate
pip install -r tools/requirements-license-scan.txt
```

The versions in `requirements-license-scan.txt` are pinned to what was tested against this repository.
Do not casually bump them: scanner output and match behaviour can change between releases.

The dependency stage additionally requires:

- Docker Desktop (or another working Docker engine)
- `jq`

On macOS, verify Docker before running the full audit:

```bash
docker info
docker run --rm ghcr.io/oss-review-toolkit/ort --version
```

The ORT helper script contains the Apple Silicon platform split required by this repository: Pub /
Flutter analysis runs under `linux/amd64`, while Mix / BEAM analysis runs natively under
`linux/arm64`.

### Running the complete audit

From the repository root, with the license-scan environment activated:

```bash
bash tools/provenance-audit.sh
```

The script writes its artifacts under:

```text
${TMPDIR:-/tmp}/epidemica-provenance/
```

The important outputs are:

```text
scancode.json
scanoss.json
scanoss-copyleft.json
ort/
  pub/
    analyzer/analyzer-result.json
    pub-license-lookup.json
  mix/
    analyzer/analyzer-result.json
provenance-report.md
```

`provenance-report.md` is the main human-readable result. It summarizes PASS / REVIEW / FAIL /
INCOMPLETE status, lists concrete action items first, and links back to the raw audit artifacts.

### Running individual stages

#### 1. ScanCode: first-party embedded license / copyright detection

```bash
bash tools/license-scan.sh /tmp/license-scan.json
python3 tools/check-license-scan.py /tmp/license-scan.json
```

`license-scan.sh` scans the repository's selected first-party source paths one at a time. This avoids
ScanCode choosing a common ancestor and accidentally traversing `.venv`, `deps/`, build output, and
other third-party trees.

`check-license-scan.py` applies the project allow-list:

- **REJECT** — GPL / AGPL / LGPL-family license text in first-party source. This is a release blocker
  until investigated.
- **REVIEW** — another meaningful license match that is neither on the allow-list nor automatically
  rejected. Review it manually; the checker does not fail merely because a scanner produced an
  ambiguous result.
- **Clean** — no actionable copyleft license text was found.

Before removing flagged code, inspect the actual file and context. A comment documenting why GPL code
was avoided can itself trigger a text matcher. Do not silence real findings by broadly excluding source
paths or weakening the copyleft policy.

#### 2. SCANOSS: first-party source provenance / similarity

```bash
bash tools/scanoss-scan.sh /tmp/scanoss.json
python3 tools/check-scanoss.py /tmp/scanoss-copyleft.json
bash tools/list-scanoss-matches.sh /tmp/scanoss.json
```

SCANOSS fingerprints the same first-party source universe and looks for `file` and `snippet` matches
against known open-source components. The match listing includes:

- local file and line range
- match type and percentage
- upstream component and version
- upstream file and line range
- PURL and detected license

Treat a copyleft SCANOSS match as **REVIEW**, not as automatic proof of contamination. Compare the
local and upstream code and determine whether the similarity is distinctive implementation logic,
framework-generated code, common boilerplate, or a functionally constrained pattern.

The public OSSKB API is rate-limited. A result such as:

```text
Rate limit exceeded
```

means the SCANOSS stage is **INCOMPLETE**, not that a provenance problem was found. The server response
includes a `retry_after` value; rerun only the SCANOSS stage after that window rather than repeating the
entire audit.

#### 3. ORT: dependency graph and license audit

```bash
bash tools/ort-dependency-audit.sh /tmp/epidemica-ort

python3 tools/lookup-pub-licenses.py \
  /tmp/epidemica-ort/pub/analyzer/analyzer-result.json \
  /tmp/epidemica-ort/pub/pub-license-lookup.json

bash tools/list-ort-dependencies.sh /tmp/epidemica-ort
```

`ort-dependency-audit.sh` runs only the ORT Analyzer. It resolves:

- Pub / Flutter dependencies
- Mix / Hex dependencies

The repository uses a Pub workspace, while ORT currently expects a local `pubspec.lock` beside each
`pubspec.yaml`. The helper script temporarily disables workspace resolution, creates the local state
ORT needs, runs the analysis, and cleans those generated files up afterward. It refuses to overwrite
pre-existing `pubspec_overrides.yaml` files.

For Pub packages, ORT generally resolves the package graph correctly but does not populate useful
license metadata. `lookup-pub-licenses.py` therefore uses each exact `source_artifact` recorded by ORT,
verifies SHA-256 where available, extracts only root `LICENSE` / `LICENCE` / `COPYING`-style files, and
runs ScanCode over those files. It does **not** scan dependency source code.

`list-ort-dependencies.sh` combines ORT and Pub-license results into a conservative policy report:

- **ALLOW** — the SPDX expression contains only explicitly approved permissive licenses:
  Apache-2.0, MIT, BSD-2-Clause, BSD-3-Clause, or ISC.
- **REVIEW** — copyleft, weak-copyleft, custom, unknown, exception-bearing, unparsable, or otherwise
  unapproved licenses.

A REVIEW result is not automatically incompatible with Apache-2.0. It means the dependency's actual
use and distribution obligations need a human decision.

### Generating the Markdown report manually

The full provenance script generates the report automatically. To regenerate it from existing audit
artifacts:

```bash
python3 tools/generate-provenance-report.py \
  "${TMPDIR:-/tmp}/epidemica-provenance" \
  "${TMPDIR:-/tmp}/epidemica-provenance/provenance-report.md"
```

The report prioritizes action items, then summarizes:

1. first-party ScanCode findings,
2. SCANOSS provenance matches,
3. dependency licenses,
4. coverage gaps and limitations, and
5. paths to the raw evidence files.

### Reading the final status

- **PASS** — the automated check found no issue requiring attention within that stage's coverage.
- **REVIEW** — a finding needs human interpretation but is not automatically a release blocker.
- **FAIL** — a blocking policy finding exists, such as actionable copyleft license text embedded in
  first-party source.
- **INCOMPLETE** — the stage could not provide a complete result, for example because SCANOSS was
  rate-limited or an expected analyzer artifact is missing.

The overall report takes the most conservative applicable state. Do not treat INCOMPLETE as PASS.

### Current coverage limits

The automated dependency audit currently resolves **Pub and Mix** dependencies. It does not yet resolve
Python dependencies from `models/pyproject.toml` or `analysis/pyproject.toml`; the Markdown report calls
this out as a coverage gap.

The Pub analyzer is also configured with `pubDependenciesOnly: true`. Native Android Gradle and iOS
CocoaPods dependencies pulled in through Flutter plugins are therefore outside the current dependency
license report.

These gaps do not weaken the first-party ScanCode / SCANOSS provenance checks, but they matter if the
goal is a complete bill of materials for every artifact shipped on every platform.

### When to run it

Run the provenance audit:

- **Before opening a pull request after a long agent-assisted session**, especially when many files
  changed in one sitting.
- **When adding or changing third-party dependencies**, including changes to `pubspec.yaml`, `mix.exs`,
  or `pyproject.toml`.
- **Before tagging a release**, as the final provenance and license sweep.

For quick development feedback, it is fine to run only the relevant individual stage. For a release,
run the complete `provenance-audit.sh` and keep the Markdown report together with the raw JSON artifacts
for the release record.

## Transcript renderer

`tools/render-transcript.py` turns a Copilot session's raw `.jsonl` log into a readable Markdown
transcript: every message from both sides in full, tool calls reduced to one line each so the record
reads as the reasoning rather than the scrollback.

### Why you'd want this

A rendered transcript is a record of the human direction, review, and iterative refinement behind an
AI-assisted change — the kind of evidence copyright authorities look at when assessing whether a work
has the human authorship needed for protection. See [Licensing](../docs/concepts/licensing.md) for the
fuller reasoning and its limits: **this script produces a record, not a legal opinion, and rendering a
transcript doesn't make anything copyrightable by itself.**

Keep transcripts for changes you'd want to be able to show your own creative control over later. This
repository does not keep them checked in for every session because the raw logs are many megabytes
each; render one when you actually want the artifact.

### Finding the raw log

VS Code Copilot Chat writes one `.jsonl` per session under your workspace storage, typically:

```text
~/Library/Application Support/Code/User/workspaceStorage/<workspace-hash>/GitHub.copilot-chat/transcripts/<session-id>.jsonl
```

Linux and Windows equivalents live under the platform's own `Code/User/workspaceStorage/`. The exact
session ID is shown in the chat view's session picker.

### Running it

```bash
python3 tools/render-transcript.py <session.jsonl> <out.md>
```

To render only part of a session — the work done in one sitting, or the exchanges relevant to one
feature — use `--since` / `--until` with an ISO-8601 timestamp. A date or time with no timezone is
treated as UTC, matching how the log timestamps its events:

```bash
python3 tools/render-transcript.py <session.jsonl> <out.md> --since 2026-09-05 --until 2026-09-06
python3 tools/render-transcript.py <session.jsonl> <out.md> --since 2026-09-05T09:00:00Z
```

Both bounds are inclusive. Either can be omitted to leave that end of the range open. The rendered
file's header always states the full session span alongside the range actually rendered, so a trimmed
transcript still says what it was trimmed from.

### A schema note worth knowing before you trust the output

The event schema this script reads is VS Code Copilot Chat's own internal log format, not a stable
public API — it has already changed once. An earlier version of this script looked for `error` /
`errorMessage` fields on a failed tool call; the actual field, confirmed against a real transcript, is
a plain `success: false` with no error text at all. If a future Copilot Chat release changes the schema
again, the symptom may be the same as last time: the script keeps running and produces plausible output
that silently drops information rather than erroring. Spot-check a render against the raw `.jsonl`
after a VS Code Copilot Chat update before trusting it for something that matters.
