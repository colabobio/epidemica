# CLAUDE.md

@AGENTS.md

The file above is the shared instruction set, used by every agent that reads `AGENTS.md`. Keep
changes there, not here, so the two cannot drift. This file holds only what is specific to Claude
Code.

## Nested instructions

`contracts/`, `server/`, `models/` and `packages/` each have their own `AGENTS.md` with the local
rules. They are **not** imported here — read the one nearest the code you are changing, when you get
there. Importing all of them at launch would load the whole set into context for a change that
touches one directory.

## Skills

`.claude/skills/` holds the repeatable workflows in this repo:

| Skill | Use it when |
|---|---|
| `verify-all` | Before claiming any change is done |
| `teeth-check` | After writing a test for a bug fix |
| `add-contract` | Adding or versioning a JSON Schema |
| `run-debug-study` | Exercising the epigame pipeline end to end |

## Working here

Long sessions in this repo tend to accumulate temporary files, scratch studies in the dev database,
and formatter churn in files that were never touched. Before finishing, check `git status` and
confirm every modified file is one you meant to change.

The `tasks/` directory is where known-but-unfixed problems live, with the investigation already
done. Read it before concluding something is undiscovered, and add to it rather than fixing
something adjacent to your actual task.
