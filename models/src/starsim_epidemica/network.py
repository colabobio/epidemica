# SPDX-License-Identifier: Apache-2.0
"""``ContactNetwork``: replays measured contact episodes as Starsim edges.

This is the bridge that lets any Starsim disease module run over an empirically measured
contact network instead of a generated one.

Starsim computes per-edge transmission as ``edges.beta * disease.pars.beta``. So
``disease.pars.beta`` stays the per-reference-exposure transmission rate, and ``edges.beta``
carries the measured exposure for that dyad during the timestep, expressed as a multiple of
:data:`~starsim_epidemica.episodes.REFERENCE_EXPOSURE_S`.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Iterable, Mapping

import numpy as np
import starsim as ss

from .cohort import ParticipantIndex, get_module
from .episodes import (
    DEFAULT_BAND_WEIGHTS,
    REFERENCE_EXPOSURE_S,
    ContactEpisode,
)


class ContactNetwork(ss.Network):
    """A Starsim network driven by recorded :class:`ContactEpisode` data.

    Args:
        episodes: measured episodes. Both participants' recordings of the same encounter
            may be supplied; see ``reconcile``.
        index: pseudonym/uid mapping.
        weights: per-band dose weights.
        reference_exposure_s: weighted exposure corresponding to an edge weight of 1.0.
        max_beta: optional cap on edge weight, guarding against a single implausibly long
            episode dominating transmission.
        reconcile: how to combine the two sides' recordings of one encounter within a
            timestep -- ``"max"`` (default, trusts the better-placed device), ``"mean"``,
            or ``"sum"`` (only when episodes are known to be one-sided).
        cohort: name of an :class:`OpenCohort` module; when set, edges touching a
            non-enrolled agent are dropped.
    """

    def __init__(
        self,
        episodes: Iterable[ContactEpisode],
        index: ParticipantIndex,
        *,
        weights: Mapping[str, float] = DEFAULT_BAND_WEIGHTS,
        reference_exposure_s: float = REFERENCE_EXPOSURE_S,
        max_beta: float | None = None,
        reconcile: str = "max",
        cohort: str | None = "cohort",
        name: str = "contacts",
        label: str = "Measured contacts",
        **kwargs,
    ) -> None:
        super().__init__(name=name, label=label, **kwargs)
        if reconcile not in ("max", "mean", "sum"):
            raise ValueError(f"unknown reconcile mode: {reconcile}")
        self.index = index
        self.weights = dict(weights)
        self.reference_exposure_s = float(reference_exposure_s)
        self.max_beta = max_beta
        self.reconcile = reconcile
        self.cohort_name = cohort
        self._cohort = None
        self._bins: list[tuple[np.ndarray, np.ndarray, np.ndarray]] = []
        # Episodes are flattened to NumPy arrays here and the objects then dropped. Starsim
        # recursively walks every module attribute at init to discover distributions and time
        # parameters; leaving ~10^5 episode dataclasses reachable from a module makes that walk
        # traverse millions of objects and turns sim.init() into minutes. Arrays are opaque to it.
        (self._u1, self._u2, self._w, self._t0, self._t1, self.stats) = self._flatten(episodes)
        self._key = self._u1 * len(index) + self._u2

    def _flatten(self, episodes: Iterable[ContactEpisode]):
        u1, u2, w, t0, t1 = [], [], [], [], []
        dropped_unknown = dropped_self = dropped_zero = 0
        n_in = 0
        for ep in episodes:
            n_in += 1
            if ep.observer not in self.index or ep.peer not in self.index:
                dropped_unknown += 1
                continue
            a, b = self.index.uid(ep.observer), self.index.uid(ep.peer)
            if a == b:
                dropped_self += 1
                continue
            weight = ep.edge_weight(self.weights, self.reference_exposure_s)
            if weight <= 0:
                dropped_zero += 1
                continue
            lo, hi = (a, b) if a < b else (b, a)
            u1.append(lo)
            u2.append(hi)
            w.append(weight)
            t0.append(ep.started_at.timestamp())
            t1.append(ep.ended_at.timestamp())
        stats = {
            "episodes_in": n_in,
            "episodes_kept": len(w),
            "dropped_unknown_participant": dropped_unknown,
            "dropped_self_contact": dropped_self,
            "dropped_zero_exposure": dropped_zero,
        }
        return (
            np.asarray(u1, dtype=np.int64),
            np.asarray(u2, dtype=np.int64),
            np.asarray(w, dtype=np.float64),
            np.asarray(t0, dtype=np.float64),
            np.asarray(t1, dtype=np.float64),
            stats,
        )

    # -- setup -----------------------------------------------------------------------

    def init_post(self, add_pairs: bool = False) -> None:
        super().init_post(add_pairs=False)
        self._cohort = get_module(self.sim, self.cohort_name) if self.cohort_name else None
        self._bin_episodes()

    def _bin_episodes(self) -> None:
        """Apportion every episode across the timesteps it overlaps, once, up front."""
        starts = np.array([t.timestamp() for t in self.sim.t.timevec], dtype=float)
        n_steps = len(starts)
        if n_steps > 1:
            widths = np.append(np.diff(starts), np.diff(starts)[-1])
        else:
            widths = np.array([86400.0])

        n = len(self.index)
        span = self._t1 - self._t0
        zero_span = span <= 0
        placements = 0
        total_weight = 0.0
        bins = []

        for ti in range(n_steps):
            w0 = starts[ti]
            w1 = w0 + widths[ti]
            overlap = np.minimum(self._t1, w1) - np.maximum(self._t0, w0)
            inside = zero_span & (self._t0 >= w0) & (self._t0 < w1)
            sel = (overlap > 0) | inside
            if not sel.any():
                bins.append(self._empty_bin())
                continue

            frac = np.zeros_like(span)
            partial = sel & ~zero_span
            frac[partial] = np.clip(overlap[partial] / span[partial], 0.0, 1.0)
            frac[inside] = 1.0

            vals = self._w[sel] * frac[sel]
            placements += int(sel.sum())
            total_weight += float(vals.sum())
            bins.append(self._aggregate(self._key[sel], vals, n))

        self._bins = bins
        self.stats.update(
            {
                "episode_timestep_placements": placements,
                "total_edge_weight": total_weight,
                "max_edges_in_a_step": max((len(b[0]) for b in bins), default=0),
            }
        )

    def _empty_bin(self):
        empty_i = np.empty(0, dtype=np.int64)
        return empty_i, empty_i, np.empty(0, dtype=self.meta.beta)

    def _aggregate(self, keys: np.ndarray, vals: np.ndarray, n: int):
        """Combine the (possibly two-sided) recordings of each dyad into a single edge."""
        uniq, inverse = np.unique(keys, return_inverse=True)
        if self.reconcile == "max":
            agg = np.zeros(len(uniq), dtype=np.float64)
            np.maximum.at(agg, inverse, vals)
        elif self.reconcile == "sum":
            agg = np.zeros(len(uniq), dtype=np.float64)
            np.add.at(agg, inverse, vals)
        else:  # mean
            sums = np.zeros(len(uniq), dtype=np.float64)
            counts = np.zeros(len(uniq), dtype=np.float64)
            np.add.at(sums, inverse, vals)
            np.add.at(counts, inverse, 1.0)
            agg = sums / counts

        if self.max_beta is not None:
            agg = np.minimum(agg, self.max_beta)
        return (uniq // n).astype(np.int64), (uniq % n).astype(np.int64), agg.astype(self.meta.beta)

    # -- per-timestep ----------------------------------------------------------------

    def step(self) -> None:
        p1, p2, beta = self._bins[self.ti] if self.ti < len(self._bins) else self._empty_bin()

        if self._cohort is not None and len(p1):
            active = self._cohort.active.raw.astype(bool)
            keep = active[p1] & active[p2]
            p1, p2, beta = p1[keep], p2[keep], beta[keep]

        self.edges.p1 = ss.uids(p1)
        self.edges.p2 = ss.uids(p2)
        self.edges.beta = beta

    def init_results(self) -> None:
        super().init_results()
        # ss.Network already defines n_edges; only the exposure total is ours.
        self.define_results(
            ss.Result("total_exposure", dtype=float, label="Summed edge weight this step"),
        )

    def update_results(self) -> None:
        super().update_results()
        self.results.total_exposure[self.ti] = float(np.sum(self.edges.beta)) if len(self.edges.beta) else 0.0
