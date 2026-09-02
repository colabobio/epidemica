# SPDX-License-Identifier: Apache-2.0
"""Starsim bridge for Epidemica.

Exposes measured contact networks and open-cohort enrollment as first-class Starsim
modules, so any Starsim disease module can run over empirically observed contacts.
"""

from .cohort import CohortInfectionTracker, OpenCohort, ParticipantIndex
from .episodes import (
    BAND_NAMES,
    DEFAULT_BAND_EDGES_M,
    DEFAULT_BAND_WEIGHTS,
    REFERENCE_EXPOSURE_S,
    ContactEpisode,
    dump_jsonl,
    load_jsonl,
    load_schema,
    pair_key,
    validate_payload,
)
from .network import ContactNetwork

__version__ = "0.0.1"

__all__ = [
    "BAND_NAMES",
    "DEFAULT_BAND_EDGES_M",
    "DEFAULT_BAND_WEIGHTS",
    "REFERENCE_EXPOSURE_S",
    "CohortInfectionTracker",
    "ContactEpisode",
    "ContactNetwork",
    "OpenCohort",
    "ParticipantIndex",
    "dump_jsonl",
    "load_jsonl",
    "load_schema",
    "pair_key",
    "validate_payload",
]
