# SPDX-License-Identifier: Apache-2.0
"""Synthetic contact episodes for testing the bridge without a real deployment.

Per the spike scope, this generates *plausibly structured* rather than *validated* contact
data: a household/class/random mixture that produces the clustering and repeated-dyad
structure real proximity data shows. It is sufficient to exercise the plumbing, the
open-cohort logic and performance. It is **not** evidence that Starsim reproduces a real
Epidemica deployment -- that requires Spike B against an exported deployment (ADR-0012).
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Iterator, Mapping

import numpy as np

from .episodes import BAND_NAMES, DEFAULT_BAND_EDGES_M, ContactEpisode

#: Contact archetypes: (mean duration s, band mixture, mean daily encounters per dyad).
_ARCHETYPES = {
    "household": (5400.0, {"immediate": 0.35, "close": 0.40, "medium": 0.20, "far": 0.05}),
    "class":     (1800.0, {"immediate": 0.05, "close": 0.25, "medium": 0.45, "far": 0.25}),
    "random":    (300.0,  {"immediate": 0.02, "close": 0.10, "medium": 0.30, "far": 0.58}),
}

MAX_EPISODE_S = 900.0


def make_cohort(
    n_participants: int = 300,
    study_days: int = 21,
    enrollment_days: int = 7,
    dropout_frac: float = 0.10,
    start: datetime | None = None,
    seed: int = 0,
) -> tuple[list[str], dict[str, tuple[datetime, datetime | None]], datetime, datetime]:
    """Build pseudonyms and a rolling enrollment schedule with dropout."""
    rng = np.random.default_rng(seed)
    start = start or datetime(2026, 3, 2, tzinfo=timezone.utc)
    stop = start + timedelta(days=study_days)

    pseudonyms = [f"p{i:05d}" for i in range(n_participants)]
    enrollment: dict[str, tuple[datetime, datetime | None]] = {}
    for p in pseudonyms:
        joined = start + timedelta(days=float(rng.integers(0, enrollment_days)))
        left = None
        if rng.random() < dropout_frac:
            remaining = (stop - joined).days
            if remaining > 1:
                left = joined + timedelta(days=float(rng.integers(1, remaining)))
        enrollment[p] = (joined, left)
    return pseudonyms, enrollment, start, stop


def _split_episode(
    observer: str,
    peer: str,
    begin: datetime,
    total_s: float,
    mixture: Mapping[str, float],
    rng: np.random.Generator,
) -> Iterator[ContactEpisode]:
    """Emit an encounter as one or more episodes, none longer than MAX_EPISODE_S.

    Real apps must do this too: bounded episodes keep temporal apportionment into
    simulation timesteps accurate and bound the memory an episode accumulates on-device.
    """
    remaining = total_s
    cursor = begin
    while remaining > 0:
        chunk = min(remaining, MAX_EPISODE_S)
        band_seconds = {b: chunk * mixture.get(b, 0.0) for b in BAND_NAMES}
        observed = sum(band_seconds.values())
        if observed <= 0:
            return
        yield ContactEpisode(
            observer=observer,
            peer=peer,
            started_at=cursor,
            ended_at=cursor + timedelta(seconds=chunk),
            band_seconds=band_seconds,
            sample_count=max(1, int(chunk / 30)),
            gap_count=int(rng.poisson(0.3)),
            min_distance_m=float(DEFAULT_BAND_EDGES_M[0] * rng.uniform(0.3, 1.0)),
            observer_device_class="ios" if rng.random() < 0.5 else "android",
            peer_device_class="ios" if rng.random() < 0.5 else "android",
            truncated=remaining > MAX_EPISODE_S,
        )
        cursor += timedelta(seconds=chunk)
        remaining -= chunk


def make_episodes(
    pseudonyms: list[str],
    enrollment: Mapping[str, tuple[datetime, datetime | None]],
    start: datetime,
    stop: datetime,
    household_size: int = 4,
    class_size: int = 30,
    p_class_contact: float = 0.15,
    n_random_per_day: float = 1.5,
    both_sides: bool = True,
    seed: int = 0,
) -> list[ContactEpisode]:
    """Generate episodes with household, class and random mixing."""
    rng = np.random.default_rng(seed + 1)
    n = len(pseudonyms)
    order = rng.permutation(n)
    household = {pseudonyms[u]: int(i // household_size) for i, u in enumerate(order)}
    klass = {pseudonyms[u]: int(i // class_size) for i, u in enumerate(order)}

    by_household: dict[int, list[str]] = {}
    by_class: dict[int, list[str]] = {}
    for p in pseudonyms:
        by_household.setdefault(household[p], []).append(p)
        by_class.setdefault(klass[p], []).append(p)

    def enrolled_on(p: str, day: datetime) -> bool:
        joined, left = enrollment[p]
        return joined <= day and (left is None or day < left)

    episodes: list[ContactEpisode] = []
    n_days = (stop - start).days

    for d in range(n_days):
        day = start + timedelta(days=d)
        present = [p for p in pseudonyms if enrolled_on(p, day)]
        if len(present) < 2:
            continue
        present_set = set(present)

        def emit(a: str, b: str, archetype: str, hour: float) -> None:
            mean_s, mixture = _ARCHETYPES[archetype]
            total_s = float(rng.gamma(shape=2.0, scale=mean_s / 2.0))
            if total_s < 60:
                return
            begin = day + timedelta(hours=hour + float(rng.uniform(0, 1.5)))
            eps = list(_split_episode(a, b, begin, total_s, mixture, rng))
            episodes.extend(eps)
            if both_sides:
                # The peer's device records the same encounter independently.
                episodes.extend(e.mirrored() for e in eps)

        for members in by_household.values():
            here = [p for p in members if p in present_set]
            for i in range(len(here)):
                for j in range(i + 1, len(here)):
                    emit(here[i], here[j], "household", 19.0)

        for members in by_class.values():
            here = [p for p in members if p in present_set]
            for i in range(len(here)):
                for j in range(i + 1, len(here)):
                    if rng.random() < p_class_contact:
                        emit(here[i], here[j], "class", 10.0)

        n_random = rng.poisson(n_random_per_day * len(present) / 2)
        for _ in range(int(n_random)):
            a, b = rng.choice(len(present), size=2, replace=False)
            emit(present[a], present[b], "random", float(rng.uniform(8, 20)))

    return episodes
