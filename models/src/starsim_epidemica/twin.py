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

    edges = _edges(doc, agents, population, pars)
    sim = _build_sim(doc, population, pars, edges)
    disease = sim.diseases[0]
    day = int(doc["day"])

    _write_states(disease, agents, sim, day)
    _apply_protection(disease, agents, sim, efficacy, blocks_transmission)

    infected_before = np.array(disease.infected.raw, dtype=bool).copy()
    sim.run_one_step()

    return _read_states(doc, disease, agents, infected_before, sim, day, edges)


def _edges(doc, agents, population: int, pars: Mapping[str, Any]) -> dict[str, np.ndarray]:
    """The day's edge list: measured contacts, plus the virtual population's mixing."""
    contacts = list(doc.get("contacts") or [])
    p1 = [int(c["a"]) for c in contacts]
    p2 = [int(c["b"]) for c in contacts]
    beta = [edge_weight(c.get("band_seconds") or {}) for c in contacts]

    vp1, vp2, vbeta = _virtual_edges(doc, agents, population, pars)
    return {
        "p1": np.array(p1 + vp1, dtype=np.int64),
        "p2": np.array(p2 + vp2, dtype=np.int64),
        "beta": np.array(beta + vbeta, dtype=np.float64),
        "measured": len(p1),
    }


def _virtual_edges(doc, agents, population: int, pars: Mapping[str, Any]):
    """Daily mixing for the simulated remainder of the population.

    Virtual participants have no measured contacts, so without this they are epidemiologically
    inert and completing the population achieves nothing: a seven-day study of twenty players
    would simply never see an outbreak. Their partners are drawn from everyone, which is also the
    only route by which the wider epidemic reaches a participant.
    """
    mixing = dict(pars.get("virtual") or {})
    per_day = int(mixing.get("contacts_per_day", 0))
    virtual = [int(a["index"]) for a in agents if a.get("virtual")]
    if per_day <= 0 or not virtual or population < 2:
        return [], [], []

    weight = edge_weight(mixing.get("band_seconds") or {"close": REFERENCE_EXPOSURE_S})

    # Its own stream, seeded from the tick, so the mixing is reproducible without perturbing the
    # draws Starsim makes for transmission.
    rng = np.random.default_rng([int(doc["seed"]), 0x7717])
    p1: list[int] = []
    p2: list[int] = []
    for v in virtual:
        partners = rng.choice(population - 1, size=min(per_day, population - 1), replace=False)
        for partner in partners:
            other = int(partner) + (1 if int(partner) >= v else 0)
            p1.append(v)
            p2.append(other)
    return p1, p2, [weight] * len(p1)


def _build_sim(doc: Mapping[str, Any], population: int, pars: Mapping[str, Any], edges) -> ss.Sim:
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
    net.edges.p1 = edges["p1"]
    net.edges.p2 = edges["p2"]
    net.edges.beta = edges["beta"]
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
        level = _protection_level(agent)
        if level <= 0.0:
            continue
        uid = uids[int(agent["index"])]
        # Scaled by how much of the day the protection actually covered. Protecting at the last
        # minute would otherwise confer immunity against contacts that had already happened.
        reduction = efficacy * level
        disease.rel_sus[uid] = 1.0 - reduction
        if blocks_transmission:
            # Protection is partly altruistic: a protected participant who is already infected
            # does not pass it on either.
            disease.rel_trans[uid] = 1.0 - reduction


def _protection_level(agent: Mapping[str, Any]) -> float:
    """How much of the day an agent was protected for, as a fraction.

    Ticks written before protection was fractional carry a boolean instead, which says the same
    thing at the extremes. Reading both is what keeps a stored tick re-runnable, and a tick that
    cannot be re-run cannot be verified.
    """
    if "protection" in agent:
        return min(1.0, max(0.0, float(agent["protection"] or 0.0)))
    return 1.0 if agent.get("protected") else 0.0


def _read_states(
    doc: Mapping[str, Any],
    disease,
    agents: list[Mapping[str, Any]],
    infected_before: np.ndarray,
    sim: ss.Sim,
    day: int,
    edges,
) -> dict[str, Any]:
    uids = sim.people.auids
    exposures = _exposures(agents, edges, infected_before, uids)

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
        if became:
            record["infection"] = exposures.get(i, {"cause": "unknown", "sources": []})
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


def _exposures(agents, edges, infected_before: np.ndarray, uids) -> dict[int, dict[str, Any]]:
    """Who each agent could have caught it from, and through which pathway.

    Starsim does not expose a transmission tree, so the specific transmitting edge is not
    recoverable. What is recoverable is the exposure set -- the infectious neighbours the agent
    actually had that day -- and reporting that rather than picking one of them keeps the record
    honest about what is known. A single source is an attribution; several is an ambiguity, and
    saying so is better than inventing certainty.
    """
    by_index = {int(a["index"]): a for a in agents}
    neighbours: dict[int, list[int]] = {}
    for a, b in zip(edges["p1"], edges["p2"]):
        neighbours.setdefault(int(a), []).append(int(b))
        neighbours.setdefault(int(b), []).append(int(a))

    out = {}
    for index in by_index:
        sources = [
            n
            for n in dict.fromkeys(neighbours.get(index, []))
            if n in by_index and bool(infected_before[uids[n]])
        ]
        if not sources:
            continue

        any_real = any(not by_index[n].get("virtual") for n in sources)
        any_virtual = any(by_index[n].get("virtual") for n in sources)
        if any_real and any_virtual:
            cause = "ambiguous"
        elif any_real:
            cause = "measured_contact"
        else:
            cause = "virtual_population"

        out[index] = {
            "cause": cause,
            "sources": [
                {
                    "index": n,
                    "subject": by_index[n].get("subject"),
                    "virtual": bool(by_index[n].get("virtual", False)),
                }
                for n in sorted(sources)
            ],
        }
    return out


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


def main(argv: list[str] | None = None) -> None:
    """Run one tick: read a document from a file argument or stdin, write the result to stdout."""
    argv = sys.argv[1:] if argv is None else argv
    if argv:
        with open(argv[0], encoding="utf-8") as handle:
            doc = json.load(handle)
    else:
        doc = json.load(sys.stdin)
    json.dump(tick(doc), sys.stdout)


if __name__ == "__main__":
    main()
