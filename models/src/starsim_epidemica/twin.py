# SPDX-License-Identifier: Apache-2.0
"""One day of the digital twin.

A tick is a pure function: given the previous day's agent states, the day's reconciled contact
network, and a seed, it returns the next day's states. It holds no state of its own and runs as a
subprocess, which is what lets the server re-run any tick and get the same answer.

Starsim is the transmission engine, not the system of record. States live in Postgres between days
and are written onto the agents here, one step is taken, and they are read back out. A long-lived
simulation would lose everything on a restart and could never be re-run against a stored input.
"""

from __future__ import annotations

import json
import sys
from typing import Any, Iterable, Mapping

import numpy as np
import starsim as ss

from .episodes import DEFAULT_BAND_WEIGHTS, REFERENCE_EXPOSURE_S

#: States an agent can be in, in the order the SIR module resolves them.
STATES = ("susceptible", "infected", "recovered", "dead")

#: Per-agent clocks, carried between ticks as absolute study days.
#:
#: Starsim keeps these as offsets into whichever timeline the sim was built with, and each tick
#: builds a fresh one. Storing the raw offsets would silently reinterpret them every day, so they
#: are converted to absolute days on the way out and back again on the way in.
CLOCKS = {
    "infected_on_day": "ti_infected",
    "recovers_on_day": "ti_recovered",
    "dies_on_day": "ti_dead",
}


def edge_weight(
    band_seconds: Mapping[str, float],
    weights: Mapping[str, float] = DEFAULT_BAND_WEIGHTS,
    reference_exposure_s: float = REFERENCE_EXPOSURE_S,
) -> float:
    """Dose-weighted transmission weight for one reconciled pair.

    The same weighting the analysis bridge uses, so a network replayed offline and a network
    simulated live cannot disagree about what an edge meant.
    """
    exposure = sum(float(band_seconds.get(band, 0.0)) * w for band, w in weights.items())
    return exposure / reference_exposure_s


def tick(doc: Mapping[str, Any]) -> dict[str, Any]:
    """Advance one day.

    ``doc`` is the complete input: population, parameters, every agent's state, the day's contacts
    and the seed. Nothing is read from the environment, which is what makes a stored tick
    reproducible.
    """
    agents = list(doc["agents"])
    population = int(doc["population"])
    if len(agents) != population:
        raise ValueError(f"expected {population} agents, got {len(agents)}")

    pars = dict(doc.get("pars") or {})
    protection = dict(doc.get("protection") or {})
    efficacy = float(protection.get("efficacy", 1.0))
    blocks_transmission = bool(protection.get("blocks_transmission", True))

    sim = _build_sim(doc, population, pars)
    disease = sim.diseases[0]
    day = int(doc["day"])

    _write_states(disease, agents, sim, day)
    _apply_protection(disease, agents, sim, efficacy, blocks_transmission)

    infected_before = np.array(disease.infected.raw, dtype=bool).copy()
    sim.run_one_step()

    return _read_states(doc, disease, agents, infected_before, sim, day)


def _build_sim(doc: Mapping[str, Any], population: int, pars: Mapping[str, Any]) -> ss.Sim:
    disease_pars = dict(pars.get("diseases") or {})
    disease_pars.pop("type", None)

    # Every time-valued parameter is stated in days, explicitly. Starsim's own defaults are scaled
    # in years, and a study that omits one would silently inherit that: `beta` divided by 365, and
    # an infectious period of six years. Neither is visible by inspection -- an inherited default
    # and an explicit day-scaled value print the same repr -- so nothing is left to the default.
    beta = float(disease_pars.get("beta", 0.1))
    disease_pars["beta"] = beta if isinstance(beta, ss.Rate) else ss.perday(beta)

    dur_inf = float(disease_pars.pop("dur_inf_days", 6.0))
    dur_inf_std = float(disease_pars.pop("dur_inf_std_days", 1.0))
    disease_pars["dur_inf"] = ss.lognorm_ex(mean=ss.days(dur_inf), std=ss.days(dur_inf_std))

    # Nobody is seeded at random: who starts infected is the caller's decision, carried in the
    # agent states, so a tick is a pure function of what it was given.
    disease_pars.setdefault("init_prev", 0)
    disease_pars.setdefault("p_death", 0.0)

    contacts = list(doc.get("contacts") or [])
    p1 = np.array([int(c["a"]) for c in contacts], dtype=np.int64)
    p2 = np.array([int(c["b"]) for c in contacts], dtype=np.int64)
    beta = np.array([edge_weight(c.get("band_seconds") or {}) for c in contacts], dtype=np.float64)

    sim = ss.Sim(
        n_agents=population,
        diseases=ss.SIR(**disease_pars),
        networks=ss.StaticNet(),
        # Two days so the timeline contains a step to take; only the first is ever run.
        dur=ss.days(2),
        dt=ss.days(1),
        # Every stochastic decision in the step derives from this. Stored with the tick, so a
        # re-run is a verification rather than a fresh roll of the dice.
        rand_seed=int(doc["seed"]),
        verbose=0,
    )
    sim.init()

    # Replace whatever the static network generated with the day's measured edges.
    net = sim.networks[0]
    net.edges.p1 = p1
    net.edges.p2 = p2
    net.edges.beta = beta
    return sim


def _write_states(disease, agents: Iterable[Mapping[str, Any]], sim: ss.Sim, day: int) -> None:
    uids = sim.people.auids
    for agent in agents:
        uid = uids[int(agent["index"])]
        state = agent.get("state", "susceptible")
        disease.susceptible[uid] = state == "susceptible"
        disease.infected[uid] = state == "infected"
        disease.recovered[uid] = state == "recovered"

        # The clocks matter as much as the state. An agent restored as infected but with no
        # recovery deadline never recovers, and the epidemic quietly becomes permanent.
        for field, attr in CLOCKS.items():
            value = agent.get(field)
            if value is not None:
                getattr(disease, attr)[uid] = int(value) - day

    _seed_missing_prognoses(disease, agents, sim, day)


def _seed_missing_prognoses(disease, agents, sim: ss.Sim, day: int) -> None:
    """Give every infected agent a recovery deadline, drawing one if it is missing.

    Starsim only assigns a prognosis to agents it infects itself. An index case injected by the
    study to start the outbreak arrives already infected and with no deadline, so it would stay
    infectious for ever and no amount of correct transmission would produce a realistic epidemic.
    """
    auids = sim.people.auids
    needed = [
        int(agent["index"])
        for agent in agents
        if agent.get("state") == "infected" and agent.get("recovers_on_day") is None
    ]
    if not needed:
        return

    targets = auids[np.array(needed, dtype=np.int64)]
    disease.set_prognoses(targets)

    # set_prognoses also stamps ti_infected as "now"; restore what the agent actually carried so
    # its history is not rewritten to today every time it is restored.
    for index in needed:
        uid = auids[index]
        carried = next(a for a in agents if int(a["index"]) == index).get("infected_on_day")
        if carried is not None:
            disease.ti_infected[uid] = int(carried) - day


def _apply_protection(disease, agents, sim: ss.Sim, efficacy: float, blocks_transmission: bool) -> None:
    uids = sim.people.auids
    for agent in agents:
        if not agent.get("protected"):
            continue
        uid = uids[int(agent["index"])]
        disease.rel_sus[uid] = 1.0 - efficacy
        if blocks_transmission:
            # Protection is partly altruistic: a protected participant who is already infected
            # does not pass it on either.
            disease.rel_trans[uid] = 1.0 - efficacy


def _read_states(
    doc: Mapping[str, Any],
    disease,
    agents: list[Mapping[str, Any]],
    infected_before: np.ndarray,
    sim: ss.Sim,
    day: int,
) -> dict[str, Any]:
    uids = sim.people.auids

    out_agents = []
    newly_infected = 0
    for agent in agents:
        i = int(agent["index"])
        uid = uids[i]
        if bool(disease.infected[uid]):
            state = "infected"
        elif bool(disease.recovered[uid]):
            state = "recovered"
        elif bool(disease.susceptible[uid]):
            state = "susceptible"
        else:
            state = "dead"

        became = bool(disease.infected[uid]) and not bool(infected_before[uid])
        newly_infected += int(became)

        record = {
            "index": i,
            "subject": agent.get("subject"),
            "virtual": bool(agent.get("virtual", False)),
            "state": state,
            "newly_infected": became,
        }
        for field, attr in CLOCKS.items():
            record[field] = _absolute_day(getattr(disease, attr), uid, day)
        out_agents.append(record)

    previous_cases = int(doc.get("total_cases_before", 0))
    return {
        "day": day,
        "engine": "starsim",
        # Pinned per tick rather than assumed, so an engine upgrade mid-study shows up in the data
        # instead of having to be inferred from a deployment log.
        "engine_version": ss.__version__,
        "seed": int(doc["seed"]),
        "agents": out_agents,
        "newly_infected": newly_infected,
        "total_cases": previous_cases + newly_infected,
    }


def _absolute_day(state, uid, day: int):
    """Convert one of Starsim's timeline offsets back to an absolute study day."""
    value = state[uid]
    try:
        value = float(value)
    except (TypeError, ValueError):
        return None
    if np.isnan(value):
        return None
    return day + int(value)


def main() -> None:
    """Read a tick document on stdin, write the result on stdout."""
    doc = json.load(sys.stdin)
    json.dump(tick(doc), sys.stdout)


if __name__ == "__main__":
    main()
