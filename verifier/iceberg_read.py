"""Neutral-engine readers for Lakekeeper, shared across verifier scripts.

pyiceberg is used for exact row-count assertions and to CREATE the two event
tables (the Kafka sink runs with auto-create off). DuckDB is used for the
optional audience read (scene 05). Both are read-only against PGAA/ClickHouse —
reading back through the engine that wrote the data proves nothing — and DuckDB
in particular is deliberately not an EDB product.
"""

from __future__ import annotations

from typing import Any

import config


# ── pyiceberg ────────────────────────────────────────────────────────────────

def rest_catalog(cfg: dict[str, Any]):
    from pyiceberg.catalog.rest import RestCatalog

    cat = config.catalog(cfg)
    obj = config.object_store(cfg)
    return RestCatalog(
        "kestrel",
        **{
            "uri": cat["url"],
            "warehouse": cat["warehouse_name"],
            # Lakekeeper vends temp creds for the sts-enabled warehouse, but
            # pyiceberg still needs to know where MinIO is and that it's path-style.
            "s3.endpoint": obj["endpoint"],
            "s3.region": obj["region"],
            "s3.path-style-access": "true",
        },
    )


def pyiceberg_count(cfg: dict[str, Any], namespace: str, table: str) -> int:
    """Row count for one table, or -1 if it doesn't exist yet."""
    from pyiceberg.exceptions import NoSuchTableError

    cat = rest_catalog(cfg)
    try:
        return cat.load_table((namespace, table)).scan().to_arrow().num_rows
    except NoSuchTableError:
        return -1


def list_namespaces(cfg: dict[str, Any]) -> list[str]:
    return [".".join(ns) for ns in rest_catalog(cfg).list_namespaces()]


def list_tables(cfg: dict[str, Any], namespace: str) -> list[str]:
    cat = rest_catalog(cfg)
    try:
        return [t[-1] for t in cat.list_tables(namespace)]
    except Exception:
        return []


# ── DuckDB (optional audience read, scene 05) ────────────────────────────────

def duckdb_connect(cfg: dict[str, Any]):
    """A DuckDB connection with Lakekeeper attached as `lake`.

    DuckDB's iceberg extension needs >= 1.4 for AUTHORIZATION_TYPE 'none'.
    """
    import duckdb

    cat = config.catalog(cfg)
    obj = config.object_store(cfg)
    endpoint = obj["endpoint"].removeprefix("http://").removeprefix("https://")

    con = duckdb.connect()
    con.execute("INSTALL iceberg; LOAD iceberg;")
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute(
        f"""
        CREATE SECRET minio (
            TYPE s3, KEY_ID '{obj["access_key"]}', SECRET '{obj["secret_key"]}',
            REGION '{obj["region"]}', ENDPOINT '{endpoint}',
            URL_STYLE 'path', USE_SSL false
        );
        """
    )
    # allowall catalog -> no OAuth2; use the S3 secret directly.
    con.execute(
        f"""
        ATTACH '{cat["warehouse_name"]}' AS lake (
            TYPE iceberg, ENDPOINT '{cat["url"]}',
            AUTHORIZATION_TYPE 'none', ACCESS_DELEGATION_MODE 'none'
        );
        """
    )
    return con
