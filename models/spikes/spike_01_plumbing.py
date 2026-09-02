# SPDX-License-Identifier: Apache-2.0
"""Spike A -- plumbing, open-cohort semantics and performance.

Runs a stock Starsim disease over a synthetic Epidemica contact network with rolling
enrollment, and checks the criteria this spike can actually settle. Scientific fidelity
against a real deployment is Spike B; see ADR-0012.

    uv run --project . python spikes/spike_01_plumbing.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import starsim as ss

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from starsim_epidemica import (  # noqa: E402
    CohortInfectionTracker,
    ContactNetwork,
    OpenCohort,
    ParticipantIndex,
    validate_payload,
)
from starsim_epidemica.cohort import get_module  # noqa: E402
from starsim_epidemica.synthetic import make_cohort, make_episodes  # noqa: E402

N_PARTICIPANTS = 300
POOL_MULTIPLIER = 1.5  # pre-allocated pool is larger than the enrolled cohort
STUDY_DAYS = 21
RUNTIME_BUDGET_S = 30.0


def build_sim(episodes, index, enrollment, start, stop, seed=1, n_agents=None):
    cohort = OpenCohort(enrollment=enrollment, index=index)
    net = ContactNetwork(episodes=episodes, index=index, reconcile="max", max_beta=5.0)
    disease = ss.SIR(
        beta=ss.perday(0.45),          # per unit of reference exposure per day
        init_prev=ss.bernoulli(p=0.0),  # seeded explicitly below instead
        dur_inf=ss.lognorm_ex(mean=ss.days(6), std=ss.days(1.5)),
        p_death=ss.bernoulli(p=0.0),
    )
    sim = ss.Sim(
        pars=dict(
            n_agents=n_agents or int(len(index) * POOL_MULTIPLIER),
            start=start.strftime("%Y-%m-%d"),
            stop=stop.strftime("%Y-%m-%d"),
            dt=ss.days(1),
            rand_seed=seed,
            verbose=0,
        ),
        diseases=disease,
        networks=net,
        custom=cohort,
        analyzers=CohortInfectionTracker(disease="sir", cohort="cohort"),
    )
    return sim


def seed_infections(sim, n=5, seed=0):
    """Seed index cases among agents *already enrolled*.

    Seeding an unenrolled agent would be an exogenous infection that the open-cohort
    invariant below is specifically meant to catch, so index cases must come from the
    enrolled pool -- which is also what happens in a real study.
    """
    rng = np.random.default_rng(seed)
    cohort = get_module(sim, "cohort")
    enrolled = np.flatnonzero(cohort.active.raw.astype(bool))
    if len(enrolled) < n:
        raise RuntimeError(f"only {len(enrolled)} enrolled at t0; cannot seed {n}")
    uids = ss.uids(rng.choice(enrolled, size=n, replace=False).astype(np.int64))
    sim.diseases.sir.set_prognoses(uids)
    return uids


def run(seed: int = 1, verbose: bool = True):
    pseudonyms, enrollment, start, stop = make_cohort(
        n_participants=N_PARTICIPANTS, study_days=STUDY_DAYS, seed=0
    )
    episodes = make_episodes(pseudonyms, enrollment, start, stop, seed=0)
    index = ParticipantIndex(pseudonyms)

    # Build time counts: it is paid on every run, and it is where the cost actually lives.
    t0 = time.perf_counter()
    sim = build_sim(episodes, index, enrollment, start, stop, seed=seed)
    sim.init()
    build_s = time.perf_counter() - t0

    # Starsim copies modules on registration, so read stats off the live instance.
    net = get_module(sim, "contacts")
    seed_infections(sim, n=5, seed=0)

    t1 = time.perf_counter()
    sim.run()
    run_s = time.perf_counter() - t1
    elapsed = build_s + run_s

    res = sim.results
    out = {
        "episodes": len(episodes),
        "elapsed_s": elapsed,
        "build_s": build_s,
        "run_s": run_s,
        "net_stats": net.stats,
        "n_edges": np.array(res.contacts.n_edges),
        "n_active": np.array(res.cohort.n_active),
        "cum_infections_active": np.array(res.cohort_infections.cum_infections_active),
        "n_infected_inactive": np.array(res.cohort_infections.n_infected_inactive),
        "prevalence_active": np.array(res.cohort_infections.prevalence_active),
        "n_ever_active": np.array(res.cohort.n_ever_active),
    }
    if verbose:
        report(out, episodes)
    return out


def report(out, episodes):
    print("=" * 78)
    print("SPIKE A -- Starsim x Epidemica contact network")
    print("=" * 78)
    print(f"starsim {ss.__version__}")
    print(f"\nsynthetic input : {out['episodes']:,} episodes (both sides recorded)")
    for k, v in out["net_stats"].items():
        print(f"  {k:<32} {v:,.0f}" if isinstance(v, (int, float)) else f"  {k:<32} {v}")
    print(f"\nruntime          : {out['elapsed_s']:.2f} s  (build {out['build_s']:.2f} + run {out['run_s']:.2f})")
    print(f"enrolled (final) : {int(out['n_active'][-1]):,} of {int(out['n_ever_active'][-1]):,} ever enrolled")
    print(f"edges/day        : min {int(out['n_edges'].min()):,} | median {int(np.median(out['n_edges'])):,} | max {int(out['n_edges'].max()):,}")
    print(f"attack rate      : {int(out['cum_infections_active'][-1]):,} cumulative infections among ever-enrolled "
          f"({out['cum_infections_active'][-1] / max(out['n_ever_active'][-1], 1):.1%})")
    print(f"peak prevalence  : {out['prevalence_active'].max():.1%} of enrolled")
    print("\nenrolled / infected / edges by day")
    for ti in range(len(out["n_active"])):
        bar = "#" * int(40 * out["prevalence_active"][ti] / max(out["prevalence_active"].max(), 1e-9))
        print(f"  d{ti:<3} n={int(out['n_active'][ti]):>4} cum={int(out['cum_infections_active'][ti]):>4} "
              f"edges={int(out['n_edges'][ti]):>5}  {bar}")


def check(out, out_repeat, episodes_sample):
    print("\n" + "=" * 78)
    print("ADR-0012 SPIKE A CRITERIA")
    print("=" * 78)
    checks = []

    s = out["net_stats"]
    checks.append((
        "Every episode is consumed (no silent drops)",
        s["dropped_unknown_participant"] == 0 and s["dropped_self_contact"] == 0,
        f"dropped_unknown={s['dropped_unknown_participant']}, dropped_self={s['dropped_self_contact']}",
    ))
    checks.append((
        "Open cohort: nobody is infected while never enrolled",
        int(out["n_infected_inactive"].max()) == 0,
        f"max infected-and-never-enrolled = {int(out['n_infected_inactive'].max())}",
    ))
    checks.append((
        "Transmission actually occurs over measured contacts",
        out["cum_infections_active"][-1] > 5,
        f"cumulative infections = {int(out['cum_infections_active'][-1])} (5 seeded)",
    ))
    checks.append((
        "Enrollment ramps then holds (rolling enrollment works)",
        out["n_active"][0] < out["n_active"].max(),
        f"day0={out['n_active'][0]}, peak={out['n_active'].max()}",
    ))
    checks.append((
        "Deterministic for a fixed seed",
        np.array_equal(out["cum_infections_active"], out_repeat["cum_infections_active"]),
        "identical infection trajectories across two runs",
    ))
    checks.append((
        f"Build + run within budget ({RUNTIME_BUDGET_S:.0f} s)",
        out["elapsed_s"] < RUNTIME_BUDGET_S,
        f"{out['elapsed_s']:.2f} s (build {out['build_s']:.2f} + run {out['run_s']:.2f}) "
        f"for {out['episodes']:,} episodes / {STUDY_DAYS} days",
    ))

    ok = True
    for ep in episodes_sample:
        try:
            validate_payload(ep.to_payload())
        except Exception as exc:  # noqa: BLE001
            ok = False
            detail = f"{type(exc).__name__}: {exc}"
            break
    else:
        detail = f"{len(episodes_sample)} payloads validated"
    checks.append(("Episodes conform to the contact_episode contract", ok, detail))

    for label, passed, detail in checks:
        print(f"  [{'PASS' if passed else 'FAIL'}] {label}\n         {detail}")

    n_pass = sum(1 for _, p, _ in checks if p)
    print(f"\n{n_pass}/{len(checks)} passed")
    return n_pass == len(checks)


def scale_benchmark(sizes=((300, 21), (1000, 14), (1000, 28), (2000, 14))):
    """Answer ADR-0012 open question 3: can Starsim replay a realistic deployment?"""
    print("=" * 78)
    print("SCALE BENCHMARK")
    print("=" * 78)
    print(f"{'participants':>12} {'days':>5} {'episodes':>11} {'edges/day':>10} {'build s':>9} {'run s':>8} {'total s':>9}")
    for n, days in sizes:
        pseudonyms, enrollment, start, stop = make_cohort(n_participants=n, study_days=days, seed=0)
        t_gen = time.perf_counter()
        episodes = make_episodes(pseudonyms, enrollment, start, stop, seed=0)
        index = ParticipantIndex(pseudonyms)

        t_build = time.perf_counter()
        sim = build_sim(episodes, index, enrollment, start, stop, seed=1)
        sim.init()
        build_s = time.perf_counter() - t_build

        seed_infections(sim, n=5, seed=0)
        t_run = time.perf_counter()
        sim.run()
        run_s = time.perf_counter() - t_run

        edges = np.array(sim.results.contacts.n_edges)
        print(f"{n:>12,} {days:>5} {len(episodes):>11,} {int(np.median(edges)):>10,} "
              f"{build_s:>9.2f} {run_s:>8.2f} {build_s + run_s:>9.2f}")
        del sim, episodes


if __name__ == "__main__":
    if "--scale" in sys.argv:
        scale_benchmark()
        sys.exit(0)

    out = run(seed=1)
    out_repeat = run(seed=1, verbose=False)

    pseudonyms, enrollment, start, stop = make_cohort(n_participants=N_PARTICIPANTS, study_days=STUDY_DAYS, seed=0)
    sample = make_episodes(pseudonyms, enrollment, start, stop, seed=0)[:200]

    sys.exit(0 if check(out, out_repeat, sample) else 1)
