#!/usr/bin/env python3

import json
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <scanoss-copyleft.json>", file=sys.stderr)
        return 2

    result = json.loads(Path(argv[1]).read_text())
    components = result.get("components", [])

    if components:
        print(
            f"REVIEW — SCANOSS found {len(components)} "
            "component/license copyleft match(es):"
        )

        for component in components:
            purl = component.get("purl", "unknown")
            version = component.get("version", "unknown")

            for license_info in component.get("licenses", []):
                license_id = (
                    license_info.get("spdxid")
                    or license_info.get("name")
                    or "unknown"
                )
                print(f"  {purl}@{version}: {license_id}")

        print()
        print(
            "Inspect the raw SCANOSS file/snippet matches before changing "
            "the source. A match establishes a review lead, not by itself "
            "a legal conclusion about derivation."
        )
        return 1

    print("No copyleft file/snippet components reported by SCANOSS.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))