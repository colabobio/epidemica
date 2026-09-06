# Arms

How to run an epigame as a randomised experiment: the same outbreak, played under different
economics.

An arm is a set of scoring rules a participant is assigned when they join. The disease is shared,
the population is shared, the schedule is shared. What differs is what a contact is worth and what
protection costs — the incentives, not the epidemic. That is the question an epigame can actually
answer: do people change what they do when the price of protecting themselves changes, inside a
spread they can all see?

## The shape

`rules.pars` stays the default. A study that wants arms adds `rules.arms`:

```json
"rules": {
  "engine": "epigame",
  "pars": { "protection_cost": 1, "contact_points": 5 },
  "arms": [
    { "name": "low_cost",  "weight": 1, "pars": { "protection_cost": 1 } },
    { "name": "high_cost", "weight": 2, "pars": { "protection_cost": 2 } }
  ]
}
```

A participant's rules are `defaults + rules.pars + arm.pars`, in that order. An arm that names
nothing inherits the whole default, so the study need only state what differs.

Three things about this shape are deliberate:

**The disease is not arm-specific.** One population, one `beta`, one infectious period. That is
what makes the comparison clean: participants are reacting to different incentives inside the same
spread, not to two parallel epidemics that happen to share a server. If you want to vary the
disease, that is a different study, not an arm of this one.

**Shared windows use the most generous arm.** Carry-over lookback and contact cooldown apply to
pairs, and a pair whose members are in different arms is judged by the longer of the two. Anything
tighter would silently deny the participant whose rules promised the wider window.

**A contact between arms pays by the more permissive side.** The rule that decides whether a
contact counts is a pair-level rule — duration, protection, cooldown — and two players can disagree
about it. The only defensible reading when they do is to charge each by the rules they were shown.

## The draw

An arm is assigned once, at enrollment, and kept. `Rules.assign_arm/3` hashes `{study_id, subject}`
into a weighted bucket, so the assignment is reproducible from the record — an audit can re-derive
the split — and rejoining with the same pseudonym returns the same arm rather than redrawing it.

```elixir
draw = phash2({study_id, subject}, total_weight)
```

Weighted rather than blocked on purpose. Block randomisation balances small groups but makes the
assignment depend on join order, which two phones joining at once cannot agree on. A weighted draw
is independent per participant; imbalance at small n is the price of not having to coordinate.
Both matters are worth stating in a protocol: the split is a draw, not a guarantee of equal groups.

The existing `--arm` on `epidemica.seed_study` is the other mechanism and stays: a study with no
`arms` uses the code's arm, which is stratification by distribution channel — a different
experiment, answered by who you handed which code to. A study with `arms` randomises.

## What the player sees

Nothing, and that is the point.

The arm is in the enrollment response, so the app's scoring mirror can read it
(`RulePars.forArm(bundle.rules, enrollment.arm)`), and it is on the participant's row for analysis.
It is **not** in the state document, and the app does not render it. A participant who can see
their protection cost differs from another's is a different study from one who cannot — one where
the comparison is visible and part of the game. Whether to show it is a study-design decision, and
the current default is blind.

The aggregate stays shared. "58 of 60 infected" reads the twin, which has one population, so both
arms see the same number. A leaderboard would be misleading across arms and there is none.

## Setting one up

**1. Declare the arms in the bundle.** Give each a name, a weight, and the pars that differ.

**2. Seed once.** Arms are part of the protocol, so changing them changes the hash and registers a
new study. Set them at launch; they are not tuned live. An RCT whose groups move mid-study is not
an RCT.

**3. Join.** Every new enrollment draws an arm and the response carries it. Confirm the split is
roughly what you expected before recruiting further:

```sh
psql epidemica_server_dev -c "
SELECT arm, count(*) FROM participants GROUP BY arm ORDER BY arm;"
```

**4. Analyse by arm.** `participants.arm` is the column the whole design exists to fill. The
ledger, the awards and the contact record are all attributable to it.

## Where the arm lives

On the participant row, and nowhere else. `participants.arm` is a column, set once at enrollment and
never changed; every other table — ledger entries, awards, observations — joins back to it through
`subject`. That is the one source of truth, and the reason it is not also stamped on each
observation: two copies of the same answer would eventually disagree, and a researcher would have to
know which one to trust.

There is no researcher-facing route. The API is participant-scoped, so the way to read the split is
to query the database directly:

```sql
SELECT subject, arm
FROM participants
WHERE study_id = '<study-id>'
ORDER BY arm;
```

The enrollment response carries the arm too, so the app can score against it, but that is the
participant-facing channel. Whether a player should see their own arm is the blinding question
above, not something the platform answers.

## What this does not yet do

- **Blocks.** Weighted only. If a small group needs balanced arms, that is a known addition, and
  it changes the concurrency story — see the note in `assign_arm/3` about why it was deferred.
- **Stratified draws.** A study can be randomised *or* code-stratified, not both. A study that
  wants balance across two recruitment channels needs a join code per channel and its own `arms`,
  which is two studies sharing a protocol, not one.
- **Reporting the arm to the player.** Deliberately absent. Adding it is a study-design decision,
  not a missing feature.

## See also

- [epigames](epigame.md) — how scoring and the twin fit together
- [building a study](building-a-study.md) — the bundle as a whole
- [`contracts/bundle/1.0.0.json`](../../contracts/bundle/1.0.0.json) — where `arms` is defined
