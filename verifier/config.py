"""Shared access to demo-config.toml.

Every verifier script reads the same mounted config so the catalog name,
warehouse name, namespaces and database credentials are stated in exactly one
place.
"""

from __future__ import annotations

import os
from typing import Any

import tomli

CONFIG_PATH = os.environ.get("CONFIG_FILE", "/config/demo-config.toml")


def load() -> dict[str, Any]:
    with open(CONFIG_PATH, "rb") as f:
        return tomli.load(f)


def db_params(cfg: dict[str, Any]) -> dict[str, Any]:
    """psycopg2 params for the PGD transactional database.

    Uses the in-network host/port (pgd:5432), not the published host port
    (localhost:7432) — verifier scripts run as a container on the Compose network.
    """
    t = cfg["database"]["transactional"]
    return {
        "host": t["host"],
        "port": t["port"],
        "database": t["database"],
        "user": t["user"],
        "password": t["password"],
    }


def whpg_params(cfg: dict[str, Any]) -> dict[str, Any]:
    w = cfg["database"]["warehouse"]
    return {
        "host": os.environ.get("WHPG_HOST", w["host"]),
        "port": int(os.environ.get("WHPG_PORT", w["port"])),
        "database": os.environ.get("WHPG_DB", w["database"]),
        "user": os.environ.get("WHPG_USER", w["user"]),
    }


def namespaces(cfg: dict[str, Any]) -> dict[str, Any]:
    """The three Iceberg namespaces, fixed by writer."""
    return cfg["namespaces"]


def demo_data(cfg: dict[str, Any]) -> dict[str, Any]:
    return cfg["demo_data"]


def hero(cfg: dict[str, Any]) -> dict[str, Any]:
    return cfg["hero"]


def kafka(cfg: dict[str, Any]) -> dict[str, Any]:
    return cfg["kafka"]


def catalog(cfg: dict[str, Any]) -> dict[str, Any]:
    return cfg["catalog"]


def object_store(cfg: dict[str, Any]) -> dict[str, Any]:
    return cfg["object_store"]
