# SPDX-License-Identifier: Apache-2.0
"""Add the virtual population's mixing to an exported twin network.

The engine draws virtual contacts inside each tick rather than storing them, because they are a
pure function of the tick's seed and so are reproducible from it. That makes them cheap to leave
out of the database and impossible to recover in Elixir, which cannot replay a numpy generator.

They are rebuilt here by calling the same function the tick called, with the same seed. Without
them a visualisation shows participants becoming infected with nothing touching them: at ordinary
settings the virtual population supplies most of a real participant's exposure.

    uv run python -m starsim_epidemica.netviz network.json
"""

from __future__ import annotations

import json
import sys
from typing import Any, Mapping, Sequence

from .twin import _virtual_edges, edge_weight


def virtual_edges(
    day: Mapping[str, Any], agents: Sequence[Mapping[str, Any]]
) -> list[dict[str, Any]]:
    """The virtual edges the engine used on this day, rebuilt from its seed."""
    doc = {"seed": day["seed"]}
    population = int(day.get("population") or len(agents))
    pars = dict(day.get("pars") or {})

    # `_virtual_edges` reads only the index and the virtual flag, both of which the roster carries.
    roster = [{"index": a["index"], "virtual": a["virtual"]} for a in agents]
    p1, p2, weights = _virtual_edges(doc, roster, population, pars)

    return [
        {"a": int(a), "b": int(b), "weight": float(w), "kind": "virtual"}
        for a, b, w in zip(p1, p2, weights)
    ]


def enrich(document: dict[str, Any]) -> dict[str, Any]:
    """Give every measured edge its dose weight, then add the virtual ones."""
    agents = document["agents"]

    for day in document["days"]:
        for edge in day["edges"]:
            if "weight" not in edge:
                # The same dose weighting the engine applied, so a heavier line on screen means
                # the same thing as a stronger edge in the model.
                edge["weight"] = edge_weight(edge.get("band_seconds") or {})

        day["edges"].extend(virtual_edges(day, agents))

    return document


def main(argv: list[str] | None = None) -> None:
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        raise SystemExit("usage: python -m starsim_epidemica.netviz <network.json>")

    path = argv[0]
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)

    enrich(document)

    with open(path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2)
        handle.write("\n")

    measured = sum(1 for d in document["days"] for e in d["edges"] if e["kind"] == "measured")
    virtual = sum(1 for d in document["days"] for e in d["edges"] if e["kind"] == "virtual")
    print(
        f"{path}: {measured} measured and {virtual} virtual edges "
        f"across {len(document['days'])} days"
    )


if __name__ == "__main__":
    main()
