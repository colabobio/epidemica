# starsim-epidemica

Starsim bridge for Epidemica. Exposes **measured contact networks** and **open-cohort
enrollment** as first-class Starsim modules, so any Starsim disease module can run over
empirically observed contacts instead of a generated network.

Status: **spike**. See [ADR-0012](../docs/adr/0012-starsim-as-canonical-transmission-model.md).

## What is here

| Module | Purpose |
|---|---|
| `episodes.py` | `ContactEpisode` — the unit of proximity data an app uploads; exposure weighting; JSONL IO; contract validation |
| `network.py` | `ContactNetwork(ss.Network)` — replays episodes as per-timestep Starsim edges |
| `cohort.py` | `OpenCohort(ss.Module)` — rolling enrollment on a pre-allocated agent pool; `CohortInfectionTracker` for enrolled-only results |
| `synthetic.py` | Structured synthetic episodes for testing without a real deployment |
| `spikes/spike_01_plumbing.py` | Runnable end-to-end spike that self-checks the ADR-0012 criteria |

## Quick start

```bash
uv venv --python 3.13
uv pip install --python .venv/bin/python -e ".[dev]"

.venv/bin/python spikes/spike_01_plumbing.py           # end-to-end + criteria
.venv/bin/python spikes/spike_01_plumbing.py --scale   # performance
PYTHONPATH=src .venv/bin/python -m pytest tests -q     # tests
```

## How exposure becomes transmission

Starsim computes per-edge transmission as `edges.beta * disease.pars.beta`. The split is:

- `disease.pars.beta` — transmission rate per **reference exposure** (15 minutes of immediate
  contact), a property of the pathogen.
- `edges.beta` — the **measured exposure** for that dyad during the timestep, as a multiple of
  the reference, a property of the data.

Exposure is computed from time-in-distance-band rather than mean distance, because infectious
dose accumulates as duration × f(distance): two minutes at arm's length plus eight minutes
across the room is not the same encounter as ten minutes at mid-range, though both average
identically. Band weights are configurable; the defaults are illustrative, not calibrated.

## Design notes worth knowing before you extend this

**Starsim copies modules on registration.** A reference held from before `ss.Sim(...)` points at
a dead object with uninitialised states. Use `get_module(sim, name)` after `sim.init()`.

**Never store bulk Python objects on a Module.** Starsim recursively walks module attributes at
init to discover distributions and time parameters. Leaving ~10^5 episode dataclasses reachable
made that walk traverse 9.6M objects and `sim.init()` take 58 s for a 300-person study.
Flattening to NumPy arrays at construction — arrays are opaque to the walk — cut it to 0.32 s,
a ~180× difference with identical results. Any future bulk-data module must do the same.

**Both sides of an encounter are recorded.** Two devices independently log the same contact.
`ContactNetwork(reconcile=...)` combines them (`max` by default). Their disagreement is a free
data-quality signal and should eventually feed the Aim 2 network-fidelity work.

**Episodes should be short.** Apps should cap episode length (≈900 s). Apportioning an episode
across simulation timesteps assumes bands are spread uniformly through it; short episodes keep
that error negligible.

## Disease modules available upstream

Core Starsim ships `ss.SIR`, `ss.SIS`, `ss.SEIR` and `ss.NCD`. `starsim.library` adds Cholera,
Ebola, HIV and Measles, which upstream explicitly flags as illustrative examples rather than
research-grade models.

**There is no flu or COVID module in Starsim.** COVID is Covasim, a separate package. For
respiratory work here, start from `ss.SEIR` with study-specific parameters; adopting a
research-grade respiratory model is a separate decision.

## Performance

MacBook (Apple silicon), Starsim 3.6.1, daily timestep:

| Participants | Days | Episodes | Edges/day | Build | Run |
|---:|---:|---:|---:|---:|---:|
| 300 | 21 | 145,356 | 1,085 | 0.34 s | 0.02 s |
| 1,000 | 14 | 286,568 | 3,480 | 0.65 s | 0.02 s |
| 1,000 | 28 | 695,974 | 3,661 | 1.30 s | 0.02 s |
| 2,000 | 14 | 570,040 | 6,990 | 1.12 s | 0.04 s |

Comfortably inside what a daily Aim-3 feedback loop needs.

## Limitations

- Synthetic data only. Structure is plausible; it is **not** validated against a real deployment.
  That is Spike B.
- Band weights and `REFERENCE_EXPOSURE_S` are illustrative defaults, not calibrated.
- Unobserved time inside an episode (bridged detection gaps) is not imputed.
