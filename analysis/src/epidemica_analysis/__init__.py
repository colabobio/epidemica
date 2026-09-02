# SPDX-License-Identifier: Apache-2.0
"""Analysis, validation and FAIR tooling for Epidemica datasets."""

from .contracts import (
    contracts_dir,
    error_paths,
    errors,
    fixture_dir_for,
    iter_schema_paths,
    load_fixtures,
    load_schema,
    registry,
    repo_root,
    validate,
    validator_for,
)

__version__ = "0.0.1"

__all__ = [
    "contracts_dir",
    "error_paths",
    "errors",
    "fixture_dir_for",
    "iter_schema_paths",
    "load_fixtures",
    "load_schema",
    "registry",
    "repo_root",
    "validate",
    "validator_for",
]
