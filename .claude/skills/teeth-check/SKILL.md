---
name: teeth-check
description: Confirm a new regression test actually detects the bug it was written for, by temporarily reintroducing the defect. Use after writing any test for a bug fix, or when asked whether a test has teeth.
---

# Teeth check

A test written after a fix has never seen the bug. Passing proves nothing until you have watched it
fail. Every fix in this repository gets this treatment.

## Procedure

1. **Back up the file with `cp`**, not with git:

   ```sh
   cp server/lib/epidemica_server/epigame.ex /tmp/epigame.ex.bak
   ```

2. **Reintroduce the original defect** — the actual defect, minimally. Not a nearby breakage. If the
   bug was "uses today's protection when judging an earlier day", put *that* back, not a `raise`.

3. **Run only the new test** and confirm it fails, and that it fails for the stated reason:

   ```sh
   cd server && mix test test/epidemica_server/epigame_test.exs:412
   ```

   If it passes, the test does not test what you think. If it fails on a different assertion than
   expected, it is detecting something else and will keep passing when the real bug returns.

4. **Restore from the backup:**

   ```sh
   cp /tmp/epigame.ex.bak server/lib/epidemica_server/epigame.ex
   ```

5. **Re-run the full suite** to confirm the restore was clean.

## Never use git to undo step 2

`git checkout -- <file>` and `git restore <file>` discard **all** uncommitted work in that file, not
just your temporary edit. In a long session that file usually contains hours of unrelated work. This
has already destroyed real work in this repository. Restore from the `cp` backup.

If you have already lost work this way, stop and say so immediately rather than quietly rebuilding
it — the rebuild will not be identical and the difference will not be visible.

## What counts as a defect worth seeding

The failure that actually occurred. Prefer defects drawn from real data: a wrong value observed in
a ledger, a state that should have been unreachable. A hypothetical defect produces a test for a
hypothetical bug.

Some conditions are unreachable by unit test — a `--yes` flag that meant every test skipped the
confirmation branch, leaving it with zero coverage until it crashed in someone's hands. When a teeth
check cannot reach the code, that is itself the finding: say the branch is untested rather than
implying it is covered.
