# SPDX-License-Identifier: Apache-2.0
"""Contact episodes: the unit of proximity data an Epidemica app uploads.

An episode is a period of sustained proximity between two participants, already
aggregated on the device. The canonical wire format is
``contracts/observations/proximity/contact_episode/1.0.0.json``.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any, Iterable, Iterator, Mapping, Sequence

BAND_NAMES: tuple[str, ...] = ("immediate", "close", "medium", "far")

#: Upper edges in metres of the first three bands; ``far`` is unbounded. These match the
#: bands the Epigames on-device estimator already produces (CoarseDistanceModel).
DEFAULT_BAND_EDGES_M: tuple[float, float, float] = (1.0, 2.0, 5.0)

#: Relative infectious dose per second in each band. Illustrative defaults for the spike,
#: NOT calibrated values; a real study sets these from its transmission model.
DEFAULT_BAND_WEIGHTS: Mapping[str, float] = {
    "immediate": 1.00,
    "close": 0.50,
    "medium": 0.15,
    "far": 0.02,
}

#: Weighted exposure that yields an edge weight of 1.0: 15 minutes of immediate contact.
#: Chosen to match the familiar "15 minutes within 2 m" public-health exposure definition
#: so that an edge weight is interpretable rather than arbitrary.
REFERENCE_EXPOSURE_S: float = 900.0

_SCHEMA_RELPATH = "contracts/observations/proximity/contact_episode/1.0.0.json"


def _parse_ts(value: str | datetime) -> datetime:
    if isinstance(value, datetime):
        dt = value
    else:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return dt.astimezone(timezone.utc) if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def pair_key(a: str, b: str) -> str:
    """Order-independent identifier for a dyad, used to reconcile both sides' recordings."""
    lo, hi = sorted((a, b))
    return hashlib.sha256(f"{lo}\0{hi}".encode()).hexdigest()


@dataclass(frozen=True, slots=True)
class ContactEpisode:
    """One participant's recording of one encounter."""

    observer: str
    peer: str
    started_at: datetime
    ended_at: datetime
    band_seconds: Mapping[str, float]
    sample_count: int = 1
    gap_count: int = 0
    min_distance_m: float | None = None
    observer_device_class: str | None = None
    peer_device_class: str | None = None
    estimator: str = "coarse_distance"
    estimator_version: str = "2.0.0"
    band_edges_m: Sequence[float] = DEFAULT_BAND_EDGES_M
    truncated: bool = False

    def __post_init__(self) -> None:
        if self.ended_at < self.started_at:
            raise ValueError(f"episode ends before it starts: {self.started_at} > {self.ended_at}")
        missing = set(BAND_NAMES) - set(self.band_seconds)
        if missing:
            raise ValueError(f"band_seconds missing bands: {sorted(missing)}")
        if any(self.band_seconds[b] < 0 for b in BAND_NAMES):
            raise ValueError("band_seconds must be non-negative")

    @property
    def wall_seconds(self) -> float:
        """Elapsed wall-clock duration."""
        return (self.ended_at - self.started_at).total_seconds()

    @property
    def observed_seconds(self) -> float:
        """Total seconds actually attributed to a distance band.

        May be less than :attr:`wall_seconds` when detection gaps were bridged; the
        difference is unobserved time and is deliberately not imputed.
        """
        return float(sum(self.band_seconds[b] for b in BAND_NAMES))

    @property
    def pair_key(self) -> str:
        return pair_key(self.observer, self.peer)

    def exposure_seconds(self, weights: Mapping[str, float] = DEFAULT_BAND_WEIGHTS) -> float:
        """Dose-weighted exposure, in 'immediate-contact-equivalent' seconds."""
        return float(sum(self.band_seconds[b] * weights.get(b, 0.0) for b in BAND_NAMES))

    def edge_weight(
        self,
        weights: Mapping[str, float] = DEFAULT_BAND_WEIGHTS,
        reference_exposure_s: float = REFERENCE_EXPOSURE_S,
    ) -> float:
        """Exposure expressed as a multiple of the reference exposure."""
        return self.exposure_seconds(weights) / reference_exposure_s

    def overlap_fraction(self, window_start: datetime, window_end: datetime) -> float:
        """Fraction of this episode falling inside ``[window_start, window_end)``.

        Band seconds are apportioned across simulation timesteps in proportion to temporal
        overlap, which assumes the bands are spread uniformly through the episode. That
        assumption is why apps SHOULD cap episode length (see ``truncated`` in the schema):
        with episodes bounded well below the timestep, the apportionment error is negligible.
        """
        span = self.wall_seconds
        lo = max(self.started_at, window_start)
        hi = min(self.ended_at, window_end)
        overlap = (hi - lo).total_seconds()
        if overlap <= 0:
            return 0.0
        if span <= 0:  # instantaneous episode inside the window
            return 1.0
        return overlap / span

    # -- serialisation ---------------------------------------------------------------

    def to_payload(self) -> dict[str, Any]:
        """Render as the ``payload`` of an observation envelope."""
        return {
            "peer": self.peer,
            "pair_key": self.pair_key,
            "started_at": self.started_at.isoformat().replace("+00:00", "Z"),
            "ended_at": self.ended_at.isoformat().replace("+00:00", "Z"),
            "band_seconds": {b: float(self.band_seconds[b]) for b in BAND_NAMES},
            "band_edges_m": list(self.band_edges_m),
            "min_distance_m": self.min_distance_m,
            "sample_count": int(self.sample_count),
            "gap_count": int(self.gap_count),
            "observer_device_class": self.observer_device_class,
            "peer_device_class": self.peer_device_class,
            "estimator": self.estimator,
            "estimator_version": self.estimator_version,
            "truncated": self.truncated,
        }

    @classmethod
    def from_payload(cls, payload: Mapping[str, Any], observer: str) -> "ContactEpisode":
        """Rebuild from an envelope payload; ``observer`` comes from the envelope's ``subject``."""
        return cls(
            observer=observer,
            peer=payload["peer"],
            started_at=_parse_ts(payload["started_at"]),
            ended_at=_parse_ts(payload["ended_at"]),
            band_seconds=dict(payload["band_seconds"]),
            sample_count=payload.get("sample_count", 1),
            gap_count=payload.get("gap_count", 0),
            min_distance_m=payload.get("min_distance_m"),
            observer_device_class=payload.get("observer_device_class"),
            peer_device_class=payload.get("peer_device_class"),
            estimator=payload.get("estimator", "coarse_distance"),
            estimator_version=payload.get("estimator_version", "2.0.0"),
            band_edges_m=tuple(payload.get("band_edges_m", DEFAULT_BAND_EDGES_M)),
            truncated=payload.get("truncated", False),
        )

    def mirrored(self) -> "ContactEpisode":
        """The peer's view of the same encounter, for testing reconciliation."""
        return replace(
            self,
            observer=self.peer,
            peer=self.observer,
            observer_device_class=self.peer_device_class,
            peer_device_class=self.observer_device_class,
        )


# -- schema validation ---------------------------------------------------------------


def _find_repo_root(start: Path) -> Path | None:
    for parent in [start, *start.parents]:
        if (parent / _SCHEMA_RELPATH).exists():
            return parent
    return None


@lru_cache(maxsize=1)
def load_schema() -> dict[str, Any]:
    root = _find_repo_root(Path(__file__).resolve())
    if root is None:
        raise FileNotFoundError(f"could not locate {_SCHEMA_RELPATH} above {__file__}")
    return json.loads((root / _SCHEMA_RELPATH).read_text())


def validate_payload(payload: Mapping[str, Any]) -> None:
    """Raise ``jsonschema.ValidationError`` if ``payload`` violates the contract."""
    import jsonschema

    jsonschema.validate(instance=dict(payload), schema=load_schema())


# -- IO ------------------------------------------------------------------------------


def dump_jsonl(episodes: Iterable[ContactEpisode], path: Path) -> int:
    """Write episodes as one envelope-payload-plus-observer record per line."""
    n = 0
    with Path(path).open("w") as fh:
        for ep in episodes:
            fh.write(json.dumps({"subject": ep.observer, "payload": ep.to_payload()}) + "\n")
            n += 1
    return n


def load_jsonl(path: Path, validate: bool = False) -> Iterator[ContactEpisode]:
    with Path(path).open() as fh:
        for line in fh:
            if not line.strip():
                continue
            rec = json.loads(line)
            if validate:
                validate_payload(rec["payload"])
            yield ContactEpisode.from_payload(rec["payload"], observer=rec["subject"])
