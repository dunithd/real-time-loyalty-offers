-- Interactive Kestrel lakehouse session — DuckDB (a neutral, non-EDB engine)
-- reading Iceberg via Lakekeeper. Runs on CLI startup (duckdb -init). Extensions
-- are pre-installed in the image, so these LOADs need no network.
LOAD iceberg;
LOAD httpfs;

-- Admin S3 credential (reads everything). ACCESS_DELEGATION_MODE none => DuckDB
-- uses this secret directly rather than the catalog's vended credentials.
CREATE SECRET minio (
    TYPE s3, KEY_ID 'minioadmin', SECRET 'minioadmin',
    REGION 'us-east-1', ENDPOINT 'minio:9000', URL_STYLE 'path', USE_SSL false
);

-- Attach the governed Kestrel catalog as "lake".
ATTACH 'kestrel' AS lake (
    TYPE iceberg,
    ENDPOINT 'http://lakekeeper:8181/catalog',
    AUTHORIZATION_TYPE 'none',
    ACCESS_DELEGATION_MODE 'none'
);

.timer on
.mode duckbox
.print ''
.print 'Kestrel lakehouse — DuckDB reading Iceberg via Lakekeeper (attached as "lake")'
.print 'Namespaces:  kestrel_core (PGAA)  ·  kestrel_events (Kafka sink)  ·  kestrel_analytics (PGAA CTAS)'
.print ''
.print 'The make target printed copy-paste queries above. Quick start:'
.print '  SHOW ALL TABLES;'
.print '  SELECT region, count(*) AS members FROM lake.kestrel_core.members GROUP BY 1 ORDER BY 2 DESC;'
.print ''
