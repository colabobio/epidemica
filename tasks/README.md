# tasks

Work that is known, understood, and not yet done. One file per task, moved between folders rather
than edited in place, so `git log --follow` shows when something was picked up and when it landed.

| | |
|---|---|
| [`active/`](active) | Being worked on now. Should usually hold one or two files, not ten. |
| [`backlog/`](backlog) | Understood well enough to start. A task arrives here with its problem stated and its blockers named, or it is not ready. |
| [`done/`](done) | Finished, kept for the reasoning rather than the checklist. |

## What belongs here

Things a future session needs the *context* for, not just the intent. A task file is worth writing
when the hard part is knowing what will break — the investigation is the artefact, and repeating it
is the waste.

Not a substitute for the milestone documents in [`docs/milestones`](../docs/milestones): those say
what a milestone is *for* and what would make it acceptable. These say what to change and where the
traps are.

## Format

Filename `NNNN-short-name.md`, numbered in the order they were filed. Each file states the problem,
why it matters, what is already in place, what actually blocks it, and how it would be verified.
The last of those is the one most often skipped and most often needed.
