# SPDX-License-Identifier: Apache-2.0
"""Tests for open-cohort enrollment and the contact replay network."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import numpy as np
import pytest
import starsim as ss

from starsim_epidemica import (
    CohortInfectionTracker,
    ContactEpisode,
    ContactNetwork,
    OpenCohort,
    ParticipantIndex,
)
from starsim_epidemica.cohort import get_module
from starsim_epidemica.episodes import BAND_NAMES, REFERENCE_EXPOSURE_S

START = datetime(2026, 3, 2, tzinfo=timezone.utc)
PEOPLE = ["pA", "pB", "pC", "pD"]


def episode(a, b, day, seconds=REFERENCE_EXPOSURE_S, band="immediate", hour=9):
    bands = {x: 0.0 for x in BAND_NAMES}
    bands[band] = float(seconds)
    begin = START + timedelta(days=day, hours=hour)
    return ContactEpisode(
        observer=a, peer=b, started_at=begin,
        ended_at=begin + timedelta(seconds=seconds),
        band_seconds=bands, sample_count=10,
    )


def build(episodes, enrollment, days=5, n_agents=10, seed=1, beta=0.0):
    index = ParticipantIndex(PEOPLE)
    sim = ss.Sim(
        pars=dict(n_agents=n_agents, start=START.strftime("%Y-%m-%d"),
                  stop=(START + timedelta(days=days)).strftime("%Y-%m-%d"),
                  dt=ss.days(1), rand_seed=seed, verbose=0),
        diseases=ss.SIR(beta=ss.perday(beta), init_prev=ss.bernoulli(p=0.0), p_death=ss.bernoulli(p=0.0)),
        networks=ContactNetwork(episodes=episodes, index=index),
        custom=OpenCohort(enrollment=enrollment, index=index),
        analyzers=CohortInfectionTracker(),
    )
    sim.init()
    return sim, index


def all_enrolled():
    return {p: (START, None) for p in PEOPLE}


def test_enrollment_activates_on_the_join_day():
    enrollment = {"pA": (START, None), "pB": (START + timedelta(days=2), None),
                  "pC": (START, None), "pD": (START, None)}
    sim, index = build([], enrollment)
    cohort = get_module(sim, "cohort")
    assert index.uid("pB") not in cohort.active_uids(0)
    assert index.uid("pB") in cohort.active_uids(2)


def test_departure_deactivates():
    enrollment = dict(all_enrolled())
    enrollment["pC"] = (START, START + timedelta(days=3))
    sim, index = build([], enrollment)
    cohort = get_module(sim, "cohort")
    assert index.uid("pC") in cohort.active_uids(2)
    assert index.uid("pC") not in cohort.active_uids(3)


def test_edges_are_built_from_episodes():
    sim, index = build([episode("pA", "pB", day=1)], all_enrolled())
    sim.run()
    net = get_module(sim, "contacts")
    assert net.stats["episodes_in"] == 1
    assert net.stats["dropped_unknown_participant"] == 0
    assert np.array(sim.results.contacts.n_edges)[1] == 1


def test_edge_weight_matches_reference_exposure():
    sim, _ = build([episode("pA", "pB", day=1, seconds=REFERENCE_EXPOSURE_S)], all_enrolled())
    sim.run()
    total = np.array(sim.results.contacts.total_exposure)
    assert total[1] == pytest.approx(1.0, rel=1e-3)


def test_both_sides_reconcile_to_one_edge():
    """Two independent recordings of one encounter must not double-count."""
    ep = episode("pA", "pB", day=1)
    sim, _ = build([ep, ep.mirrored()], all_enrolled())
    sim.run()
    assert np.array(sim.results.contacts.n_edges)[1] == 1
    assert np.array(sim.results.contacts.total_exposure)[1] == pytest.approx(1.0, rel=1e-3)


def test_reconcile_sum_double_counts_as_documented():
    ep = episode("pA", "pB", day=1)
    index = ParticipantIndex(PEOPLE)
    net = ContactNetwork(episodes=[ep, ep.mirrored()], index=index, reconcile="sum")
    sim = ss.Sim(
        pars=dict(n_agents=10, start=START.strftime("%Y-%m-%d"),
                  stop=(START + timedelta(days=5)).strftime("%Y-%m-%d"),
                  dt=ss.days(1), rand_seed=1, verbose=0),
        diseases=ss.SIR(beta=ss.perday(0.0)),
        networks=net,
        custom=OpenCohort(enrollment=all_enrolled(), index=index),
    )
    sim.init()
    sim.run()
    assert np.array(sim.results.contacts.total_exposure)[1] == pytest.approx(2.0, rel=1e-3)


def test_episode_spanning_two_days_is_apportioned():
    """A contact across midnight contributes to both timesteps, proportionally."""
    begin = START + timedelta(days=1, hours=23, minutes=30)
    bands = {b: 0.0 for b in BAND_NAMES}
    bands["immediate"] = 3600.0
    ep = ContactEpisode(observer="pA", peer="pB", started_at=begin,
                        ended_at=begin + timedelta(hours=1), band_seconds=bands, sample_count=10)
    sim, _ = build([ep], all_enrolled())
    sim.run()
    total = np.array(sim.results.contacts.total_exposure)
    assert total[1] == pytest.approx(total[2], rel=1e-6)
    assert total[1] + total[2] == pytest.approx(3600.0 / REFERENCE_EXPOSURE_S, rel=1e-6)


def test_edges_touching_unenrolled_agents_are_dropped():
    enrollment = dict(all_enrolled())
    enrollment["pB"] = (START + timedelta(days=3), None)
    sim, _ = build([episode("pA", "pB", day=1)], enrollment)
    sim.run()
    assert np.array(sim.results.contacts.n_edges)[1] == 0


def test_unknown_participants_are_counted_not_silently_dropped():
    ep = episode("pA", "pZZZ", day=1)
    sim, _ = build([ep], all_enrolled())
    net = get_module(sim, "contacts")
    assert net.stats["dropped_unknown_participant"] == 1


def test_self_contacts_are_rejected():
    sim, _ = build([episode("pA", "pA", day=1)], all_enrolled())
    net = get_module(sim, "contacts")
    assert net.stats["dropped_self_contact"] == 1


def test_max_beta_caps_edge_weight():
    huge = episode("pA", "pB", day=1, seconds=10 * REFERENCE_EXPOSURE_S)
    index = ParticipantIndex(PEOPLE)
    net = ContactNetwork(episodes=[huge], index=index, max_beta=2.0)
    sim = ss.Sim(
        pars=dict(n_agents=10, start=START.strftime("%Y-%m-%d"),
                  stop=(START + timedelta(days=5)).strftime("%Y-%m-%d"),
                  dt=ss.days(1), rand_seed=1, verbose=0),
        diseases=ss.SIR(beta=ss.perday(0.0)),
        networks=net,
        custom=OpenCohort(enrollment=all_enrolled(), index=index),
    )
    sim.init()
    sim.run()
    assert np.array(sim.results.contacts.total_exposure).max() == pytest.approx(2.0, rel=1e-3)


def test_unenrolled_agents_never_get_infected():
    """The core open-cohort invariant."""
    enrollment = dict(all_enrolled())
    enrollment["pD"] = (START + timedelta(days=99), None)  # never enrols in this run
    eps = [episode(a, b, day=d) for d in range(5) for a, b in
           (("pA", "pB"), ("pB", "pC"), ("pC", "pD"), ("pA", "pD"))]
    sim, index = build(eps, enrollment, beta=5.0)
    sim.diseases.sir.set_prognoses(ss.uids(np.array([index.uid("pA")], dtype=np.int64)))
    sim.run()
    assert np.array(sim.results.cohort_infections.n_infected_inactive).max() == 0
    assert sim.diseases.sir.susceptible[ss.uids(np.array([index.uid("pD")], dtype=np.int64))].all()
