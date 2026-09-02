# SPDX-License-Identifier: Apache-2.0
"""Tests for the contact episode contract and exposure weighting."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from starsim_epidemica.episodes import (
    BAND_NAMES,
    DEFAULT_BAND_WEIGHTS,
    REFERENCE_EXPOSURE_S,
    ContactEpisode,
    pair_key,
    validate_payload,
)

T0 = datetime(2026, 3, 2, 9, 0, tzinfo=timezone.utc)


def make(seconds_by_band=None, start=T0, duration_s=600):
    bands = {b: 0.0 for b in BAND_NAMES}
    bands.update(seconds_by_band or {"close": float(duration_s)})
    return ContactEpisode(
        observer="pA",
        peer="pB",
        started_at=start,
        ended_at=start + timedelta(seconds=duration_s),
        band_seconds=bands,
        sample_count=20,
    )


def test_pair_key_is_order_independent():
    assert pair_key("pA", "pB") == pair_key("pB", "pA")
    assert pair_key("pA", "pB") != pair_key("pA", "pC")


def test_mirrored_episode_shares_pair_key():
    ep = make()
    assert ep.mirrored().pair_key == ep.pair_key
    assert ep.mirrored().observer == ep.peer


def test_exposure_weighting_is_band_sensitive():
    """Equal total duration at different distances must not give equal exposure."""
    close = make({"close": 600.0})
    far = make({"far": 600.0})
    assert close.observed_seconds == far.observed_seconds
    assert close.exposure_seconds() > far.exposure_seconds()


def test_edge_weight_reference_exposure():
    """A full reference exposure of immediate contact weighs exactly 1.0."""
    ep = make({"immediate": REFERENCE_EXPOSURE_S}, duration_s=int(REFERENCE_EXPOSURE_S))
    assert ep.edge_weight() == pytest.approx(1.0)


def test_exposure_is_linear_in_duration():
    a = make({"close": 300.0}, duration_s=300)
    b = make({"close": 600.0}, duration_s=600)
    assert b.exposure_seconds() == pytest.approx(2 * a.exposure_seconds())


def test_overlap_fraction_splits_across_windows():
    ep = make(duration_s=600)  # 09:00:00 - 09:10:00
    w1 = ep.overlap_fraction(T0 - timedelta(minutes=5), T0 + timedelta(minutes=5))
    w2 = ep.overlap_fraction(T0 + timedelta(minutes=5), T0 + timedelta(minutes=15))
    assert w1 == pytest.approx(0.5)
    assert w2 == pytest.approx(0.5)
    assert w1 + w2 == pytest.approx(1.0)


def test_overlap_fraction_outside_window_is_zero():
    ep = make(duration_s=600)
    assert ep.overlap_fraction(T0 + timedelta(hours=2), T0 + timedelta(hours=3)) == 0.0


def test_observed_seconds_can_be_less_than_wall_clock():
    """Bridged detection gaps leave unobserved time, which is not imputed."""
    ep = ContactEpisode(
        observer="pA", peer="pB",
        started_at=T0, ended_at=T0 + timedelta(seconds=600),
        band_seconds={"immediate": 0.0, "close": 400.0, "medium": 0.0, "far": 0.0},
        sample_count=10, gap_count=2,
    )
    assert ep.observed_seconds == 400.0
    assert ep.wall_seconds == 600.0


def test_rejects_reversed_timestamps():
    with pytest.raises(ValueError, match="ends before it starts"):
        ContactEpisode(
            observer="pA", peer="pB",
            started_at=T0, ended_at=T0 - timedelta(seconds=1),
            band_seconds={b: 0.0 for b in BAND_NAMES},
        )


def test_rejects_missing_bands():
    with pytest.raises(ValueError, match="missing bands"):
        ContactEpisode(
            observer="pA", peer="pB", started_at=T0, ended_at=T0,
            band_seconds={"close": 10.0},
        )


def test_payload_roundtrip():
    ep = make({"immediate": 60.0, "close": 240.0})
    restored = ContactEpisode.from_payload(ep.to_payload(), observer=ep.observer)
    assert restored == ep


def test_payload_validates_against_contract():
    validate_payload(make().to_payload())


def test_payload_rejects_unknown_field():
    import jsonschema

    payload = make().to_payload()
    payload["surprise"] = 1
    with pytest.raises(jsonschema.ValidationError):
        validate_payload(payload)


def test_payload_carries_no_raw_identifiers():
    """The contract must not leak device addresses or PII."""
    payload = make().to_payload()
    assert set(payload) <= set(validate_payload.__module__ and __import__(
        "starsim_epidemica.episodes", fromlist=["load_schema"]
    ).load_schema()["properties"])
    assert "mac" not in payload and "device_address" not in payload


def test_default_weights_are_monotonic_in_distance():
    w = DEFAULT_BAND_WEIGHTS
    assert w["immediate"] > w["close"] > w["medium"] > w["far"] > 0
