# Arms

How to run an epigame as a randomised experiment: one outbreak, played at different prices.

An arm is a set of prices a participant is drawn into when they join. The disease is shared, the
population is shared, the schedule is shared. What differs is what a contact is worth and what
protection costs — the incentives, not the epidemic. That is the question an epigame is actually
able to answer: do people change what they do when the price of protecting themselves changes,
inside a spread they can all see?

A study that does not want this changes nothing. `rules.arms` is absent from every bundle written
before it existed, and an absent `arms` means one group, the same scoring, and the same protocol
hash.

## The shape

`rules.pars` stays the study's default. A study that randomises adds `rules.arms`:

```json
"rules": {
  "engine": "epigame",
  "pars": { "protection_cost": 1, "contact_points": 5 },
  "arms": [
    { "name": "low_cost",  "weight": 1, "pars": {} },
    { "name": "high_cost", "weight": 2, "pars": { "protection_cost": 2 } }
  ]
}
```

A participant's rules are `defaults + rules.pars + arm.pars`, in that order, computed by
`Rules.pars_for/2` and by nothing else. An arm naming nothing inherits the whole default, which is
how a control arm is written.

## Prices may vary. What counts as a contact may not

An arm can only name these five:

| | |
|---|---|
| `healthy_points` | what a day ending healthy is worth |
| `infected_points` | what a day ending infected is worth |
| `protection_cost` | what protection costs |
| `contact_points` | what one qualifying contact earns |
| `contact_points_while_infected` | whether contacts still earn once infected |

The other four — `contact_min_seconds`, `contact_cooldown_days`, `protection_window_seconds`,
`carry_over_days` — are shared by every arm, and the bundle schema refuses an arm that names one.

The line is not arbitrary. **The five that vary are prices, paid to one person. The four that do not
are durations, and every one of them decides something about a *pair*.** Whether an encounter
lasted long enough, whether this pair has already been paid, whether somebody was protected at the
time, how far back settlement reaches. If two participants in different arms disagreed about
whether the same encounter happened, there would be no answer that is fair to both — you would be
choosing which of the two to break, and doing it silently, inside the measurement the study exists
to make.

So the rule is: **vary what an encounter is worth, never what counts as one.**

That keeps reconciliation single-valued, which is what makes the rest simple. A contact is agreed by
shared rules, then each side is paid its own rate. A contact between `low_cost` and `high_cost` pays
one participant 5 and the other 9 for the same encounter, and neither has to know about the other.

The disease is shared for the same kind of reason, one level up. One population, one `beta`, one
infectious period — participants are reacting to different incentives inside the same spread, not to
two parallel epidemics that happen to share a server. Varying the disease is a different study, not
an arm of this one.

## The draw

An arm is drawn once, at enrolment, and kept. `Rules.assign_arm/3` derives it from
`{study_id, subject}`:

```elixir
draw = :erlang.phash2({study_id, subject}, total_weight)
```

Derived rather than sampled, so the split can be re-derived from the record during an audit, and so
a redraw is impossible even if the function were called twice. In practice it is called once:
`upsert_participant/3` only assigns on insert, so a reinstall finds the existing row and keeps its
arm. A participant whose arm moved mid-study would have their earlier days already scored under the
other one.

Weighted rather than blocked, deliberately. Block randomisation balances small groups but makes the
assignment depend on join order, which two phones joining at the same moment cannot agree on without
coordination. A weighted draw is independent per participant, and imbalance at small numbers is the
price of not needing that coordination. Worth stating in a protocol: **this is a draw, not a
guarantee of equal groups.**

## Randomised, or stratified by code — not both

`epidemica.seed_study --arm` stamps an arm on a join code. That is the other mechanism, and it
stays: it is stratification by who was handed which code, answered by distribution rather than by
chance.

A study cannot do both. `add_join_code/3` refuses an `--arm` when the protocol declares `rules.arms`,
because both decide a participant's arm and only one can win. Resolving it by precedence would
discard a design the researcher wrote down without saying so.

## What the player sees

Nothing, and that is the current default rather than a permanent answer.

The arm is in the enrolment response and on the participant's row. It is **not** in the state
document and the app does not render it. A participant who can see that their protection costs more
than someone else's is in a different study from one who cannot — one where the comparison is
visible and part of the game. Whether to show it is a study-design decision.

The aggregate stays shared: "58 of 60 infected" reads the twin, which has one population, so every
arm sees the same number.

## Registration refuses three things

All three fail at `mix epidemica.seed_study`, before anything is created:

- **An arm naming a shared duration** — the schema, for the reason above.
- **Two arms with the same name** — the name is what analysis splits by, so sharing one merges the
  conditions into a single group and leaves no trace afterwards. JSON Schema cannot express this;
  `Studies.validate_bundle/1` does.
- **A zero weight, or an empty `arms` array** — an arm nobody can be drawn into, and a draw with
  nothing to draw. A study with one group leaves `arms` out.

## Setting one up

**1. Declare the arms.** Name, weight, and the prices that differ.

**2. Seed once.** Arms are part of the protocol, so changing them changes the bundle's bytes, which
changes the hash, which is a new study. Set them at launch. An RCT whose groups move mid-study is
not an RCT.

**3. Check the split before recruiting further:**

```sh
psql epidemica_server_dev -c "
SELECT arm, count(*) FROM participants GROUP BY arm ORDER BY arm;"
```

**4. Analyse by arm.** `participants.arm` is the column the design exists to fill; the ledger, the
awards and the observations all join back to it through `subject`.

## Where the arm lives

On the participant row, and nowhere else. It is set once at enrolment and never updated. It is
deliberately not also stamped on each observation: two copies would eventually disagree, and a
researcher would have to know which to trust.

There is no researcher-facing route — the API is participant-scoped — so reading the split means
querying the database:

```sql
SELECT subject, arm FROM participants WHERE study_id = '<study-id>' ORDER BY arm;
```

## The app's mirror

`RulePars.forArm(rules, arm)` applies the same overlay in Dart that `Rules.pars_for/2` applies in
Elixir, so immediate feedback and the ledger stay one answer.

**Not yet wired.** `apps/epigames/lib/src/rules.dart` currently has no production call site — the
mirror is exercised only by `contracts/game/epigame_rules/1.0.0.vectors.json`. When a screen does
show a running score, it must pass `enrollment.arm`, which `epidemica_core` already persists. Until
then the server's ledger is the only score a participant sees, and it is already per-arm.

## What this does not yet do

- **Block randomisation.** Weighted only. Balancing small groups needs coordination between
  concurrent enrolments, which is a real change, not a tweak.
- **Both randomisation and code stratification in one study.** Refused, as above. A study needing
  balance across two recruitment channels is two studies sharing a protocol.
- **Showing a participant their arm.** Deliberately absent; a study-design decision, not a gap.

## See also

- [epigames](epigame.md) — how scoring and the twin fit together
- [surveys](surveys.md) — instruments, which are how you measure what an arm changed
- [building a study](building-a-study.md) — the bundle as a whole
- [`contracts/bundle/1.0.0.json`](../../contracts/bundle/1.0.0.json) — where `arms` is defined
