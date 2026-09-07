# models/AGENTS.md

The Starsim transmission engine. Elixir orchestrates and decides; Python simulates one day and
returns. A tick is a pure function of a JSON document — nothing is read from the environment, which
is what makes a stored tick re-runnable and therefore verifiable.

```sh
uv run pytest -q
uv run python -m starsim_epidemica.twin <tick.json>   # one day, stdin also accepted
```

## Starsim's units will bite you

**Defaults are year-scaled.** `ss.SIR()` defaults `beta` to `peryear(0.1)`, and the default
`dur_inf` resolves to roughly 2100 timesteps at `dt=ss.days(1)`.

**An inherited default and an explicit day-scaled value print the same repr.** Both show as
`ss.lognorm_ex(mean=6, std=1.0)` while behaving 365× apart. You cannot see this by inspection, so
nothing is left to a default:

```python
disease_pars["beta"] = ss.perday(beta)
disease_pars["dur_inf"] = ss.lognorm_ex(mean=ss.days(dur), std=ss.days(std))
```

**`dur=ss.days(1)` with `dt=ss.days(1)` gives zero timesteps.** The sim needs `dur=ss.days(2)` to
contain a single step.

## State lives in Postgres, not in the sim

Each tick builds a fresh sim, writes the stored states onto the agents, takes one step, reads them
back. A long-lived simulation would lose everything on restart and could never be replayed against
a stored input.

**Clocks are carried as absolute study days.** Starsim keeps `ti_infected` / `ti_recovered` /
`ti_dead` as offsets into whichever timeline the sim was built with, and each tick builds a new one.
Storing raw offsets silently reinterprets them every day. `CLOCKS` converts on the way out and back.

**An infected agent with no recovery deadline never recovers.** Starsim only assigns a prognosis to
agents it infects itself, so an index case injected by the study needs
`_seed_missing_prognoses`, or the epidemic becomes permanent and looks plausible until nobody has
recovered by day thirty.

## Two more things that are not obvious

**Virtual agents need their own mixing.** They have no measured contacts, so without
`_virtual_edges` they are epidemiologically inert and completing the population achieves nothing.
At ordinary settings they also supply most of a real participant's exposure.

**There is no transmission tree.** Starsim does not expose one, so the specific transmitting edge is
not recoverable. What is reported is the exposure *set* with a `cause` of `measured_contact`,
`virtual_population` or `ambiguous` — an attribution when there is one, an ambiguity when there is
not, rather than inventing certainty.

## Compatibility

`_protection_level` reads the current `protection` float and falls back to the older `protected`
boolean. Stored ticks are re-run to verify them, so a tick that stops being readable stops being
verifiable — which is the same as not having stored it. Keep such fallbacks, and test them.
