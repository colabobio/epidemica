# SPDX-License-Identifier: Apache-2.0
"""Open-cohort enrollment on a pre-allocated agent pool.

Starsim assumes a defined population; Epidemica studies have rolling enrollment and
dropout. Per ADR-0012 we reconcile this with a **pre-allocated pool plus an explicit
`active` state**: the sim is created with more agents than will ever enrol, every agent
stays `alive` throughout, and `OpenCohort.active` marks who is currently in the study.

Inactive agents form no edges, so they cannot transmit or be infected. Keeping them alive
(rather than using births/deaths) matters because Starsim's demographic machinery is built
for population turnover, not study membership: deaths are irreversible, so a participant
who pauses and resumes could not be represented, and mortality-based results would be
polluted by what is really an administrative event.
"""

from __future__ import annotations

from datetime import datetime
from typing import Iterable, Mapping, Sequence

import numpy as np
import starsim as ss


def get_module(sim, name: str):
    """Look up a module on a sim by name.

    Starsim *copies* modules when they are registered, so a reference held from before
    ``Sim`` construction points at a dead object with uninitialised states. Anything that
    needs a sibling module must resolve it from the sim after init.
    """
    for module in sim.modules:
        if module.name == name:
            return module
    available = [m.name for m in sim.modules]
    raise KeyError(f"no module named {name!r} on this sim; available: {available}")


class ParticipantIndex:
    """Bidirectional map between participant pseudonyms and Starsim agent uids."""

    def __init__(self, pseudonyms: Iterable[str]) -> None:
        self._to_uid: dict[str, int] = {}
        self._to_pseudonym: list[str] = []
        for p in pseudonyms:
            if p not in self._to_uid:
                self._to_uid[p] = len(self._to_pseudonym)
                self._to_pseudonym.append(p)

    def __len__(self) -> int:
        return len(self._to_pseudonym)

    def __contains__(self, pseudonym: str) -> bool:
        return pseudonym in self._to_uid

    def uid(self, pseudonym: str) -> int:
        return self._to_uid[pseudonym]

    def pseudonym(self, uid: int) -> str:
        return self._to_pseudonym[uid]

    @property
    def pseudonyms(self) -> Sequence[str]:
        return tuple(self._to_pseudonym)


class OpenCohort(ss.Module):
    """Tracks which pre-allocated agents are enrolled at each timestep.

    Args:
        enrollment: pseudonym -> (joined_at, left_at or None).
        index: participant/uid mapping. Every enrolled pseudonym must be present.
    """

    def __init__(
        self,
        enrollment: Mapping[str, tuple[datetime, datetime | None]],
        index: ParticipantIndex,
        name: str = "cohort",
        label: str = "Open cohort",
        **kwargs,
    ) -> None:
        super().__init__(name=name, label=label, **kwargs)
        self.define_states(
            ss.BoolArr("active", default=False),
            ss.BoolArr("ever_active", default=False),
        )
        self.index = index
        self._enrollment = dict(enrollment)
        self._active_uids_by_ti: list[np.ndarray] = []

    def init_post(self) -> None:
        super().init_post()
        self._bin_enrollment()
        self._apply(0)

    def _bin_enrollment(self) -> None:
        """Precompute the active set for every timestep."""
        timevec = self.sim.t.timevec
        edges = np.array([t.timestamp() for t in timevec], dtype=float)
        n_steps = len(edges)

        joins = np.full(len(self.index), np.inf)
        leaves = np.full(len(self.index), np.inf)
        for pseudonym, (joined, left) in self._enrollment.items():
            uid = self.index.uid(pseudonym)
            joins[uid] = joined.timestamp()
            leaves[uid] = np.inf if left is None else left.timestamp()

        self._active_uids_by_ti = [
            np.flatnonzero((joins <= edges[ti]) & (edges[ti] < leaves)).astype(np.int64)
            for ti in range(n_steps)
        ]

    def _apply(self, ti: int) -> None:
        if ti >= len(self._active_uids_by_ti):
            return
        uids = ss.uids(self._active_uids_by_ti[ti])
        self.active[:] = False
        if len(uids):
            self.active[uids] = True
            self.ever_active[uids] = True

    def step(self) -> None:
        self._apply(self.ti)

    def active_uids(self, ti: int) -> np.ndarray:
        """Agent uids enrolled at timestep ``ti``."""
        if ti >= len(self._active_uids_by_ti):
            return np.empty(0, dtype=np.int64)
        return self._active_uids_by_ti[ti]

    def init_results(self) -> None:
        super().init_results()
        self.define_results(
            ss.Result("n_active", dtype=int, label="Enrolled participants"),
            ss.Result("n_ever_active", dtype=int, label="Ever enrolled"),
        )

    def update_results(self) -> None:
        super().update_results()
        self.results.n_active[self.ti] = int(self.active.sum())
        self.results.n_ever_active[self.ti] = int(self.ever_active.sum())


class CohortInfectionTracker(ss.Analyzer):
    """Epidemic results restricted to enrolled agents.

    Starsim's built-in prevalence divides by the whole population, which for a
    pre-allocated pool is dominated by agents who have not enrolled. Everything reported
    here uses the enrolled population as the denominator.
    """

    def __init__(self, disease: str = "sir", cohort: str = "cohort", name: str = "cohort_infections", **kwargs) -> None:
        super().__init__(name=name, **kwargs)
        self.disease_name = disease
        self.cohort_name = cohort

    def init_results(self) -> None:
        super().init_results()
        self.define_results(
            ss.Result("n_infected_active", dtype=int, label="Infected and enrolled"),
            ss.Result("prevalence_active", dtype=float, label="Prevalence among enrolled"),
            ss.Result("cum_infections_active", dtype=int, label="Cumulative infections among ever-enrolled"),
            ss.Result("n_infected_inactive", dtype=int, label="Infected while NOT enrolled (must stay 0)"),
        )

    def step(self) -> None:
        pass

    def update_results(self) -> None:
        super().update_results()
        disease = self.sim.diseases[self.disease_name]
        cohort = get_module(self.sim, self.cohort_name)

        active = cohort.active.raw.astype(bool)
        ever = cohort.ever_active.raw.astype(bool)
        infectious = disease.infectious.raw.astype(bool)
        ever_infected = ~disease.susceptible.raw.astype(bool)

        n_active = int(active.sum())
        self.results.n_infected_active[self.ti] = int((infectious & active).sum())
        self.results.prevalence_active[self.ti] = (
            float((infectious & active).sum() / n_active) if n_active else 0.0
        )
        self.results.cum_infections_active[self.ti] = int((ever_infected & ever).sum())
        self.results.n_infected_inactive[self.ti] = int((infectious & ~ever).sum())
