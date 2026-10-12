-- Live read-only proxy over the Lakekeeper Iceberg REST catalog. All three
-- namespaces (kestrel_core via PGAA, kestrel_events via the Kafka sink,
-- kestrel_analytics via WarehousePG CTAS) appear as tables automatically.
-- ClickHouse never writes here.
--
-- Tables are referenced as iceberg_catalog.`<namespace>.<table>` (backticks
-- required). Args 2 & 3 are the S3 key/secret for reading Parquet from MinIO.
CREATE DATABASE IF NOT EXISTS iceberg_catalog
ENGINE = DataLakeCatalog('http://lakekeeper:8181/catalog', 'minioadmin', 'minioadmin')
SETTINGS
    catalog_type = 'rest',
    warehouse    = 'kestrel';
