-- Hot event path: Kafka (flat JSON) -> MergeTree hot tables, a short-lived
-- serving cache (TTL 2 days). Iceberg (kestrel_events, via the Kafka Connect
-- sink) is the long-term record; these tables are the live tier the decision
-- query reads for session features. ClickHouse does NOT write Iceberg.
--
-- Timestamps arrive as epoch millis (Int64) and are converted to DateTime64(3).

-- ── digital clickstream ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS default.digital_events_hot
(
    event_time   DateTime64(3),
    member_id    Int64,
    session_id   String,
    event_type   LowCardinality(String),
    product_id   Nullable(Int64),
    category_id  Nullable(Int64),
    channel      LowCardinality(String),
    _ingested_at DateTime64(3) DEFAULT now64(3)
)
ENGINE = MergeTree
PARTITION BY toStartOfHour(_ingested_at)
ORDER BY (session_id, event_time)
TTL toDateTime(event_time) + INTERVAL 2 DAY;

CREATE TABLE IF NOT EXISTS default.digital_events_queue
(
    event_id    String,
    event_ts    Int64,
    member_id   Int64,
    session_id  String,
    event_type  String,
    product_id  Nullable(Int64),
    category_id Nullable(Int64),
    channel     String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka:9092',
    kafka_topic_list  = 'kestrel.digital.events',
    kafka_group_name  = 'clickhouse_digital_hot',
    kafka_format      = 'JSONEachRow',
    kafka_num_consumers = 1,
    kafka_skip_broken_messages = 100;

CREATE MATERIALIZED VIEW IF NOT EXISTS default.digital_events_mv
TO default.digital_events_hot AS
SELECT
    toDateTime64(event_ts / 1000.0, 3) AS event_time,
    member_id, session_id, event_type, product_id, category_id, channel
FROM default.digital_events_queue;

-- ── offer engagement ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS default.offer_engagement_hot
(
    event_time    DateTime64(3),
    member_id     Int64,
    session_id    String,
    event_type    LowCardinality(String),   -- impression | tap | dismiss
    offer_id      Int64,
    assignment_id String,
    channel       LowCardinality(String),
    _ingested_at  DateTime64(3) DEFAULT now64(3)
)
ENGINE = MergeTree
PARTITION BY toStartOfHour(_ingested_at)
ORDER BY (offer_id, event_time)
TTL toDateTime(event_time) + INTERVAL 2 DAY;

CREATE TABLE IF NOT EXISTS default.offer_engagement_queue
(
    event_id      String,
    event_ts      Int64,
    member_id     Int64,
    session_id    String,
    event_type    String,
    offer_id      Int64,
    assignment_id String,
    channel       String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka:9092',
    kafka_topic_list  = 'kestrel.offer.engagement',
    kafka_group_name  = 'clickhouse_engagement_hot',
    kafka_format      = 'JSONEachRow',
    kafka_num_consumers = 1,
    kafka_skip_broken_messages = 100;

CREATE MATERIALIZED VIEW IF NOT EXISTS default.offer_engagement_mv
TO default.offer_engagement_hot AS
SELECT
    toDateTime64(event_ts / 1000.0, 3) AS event_time,
    member_id, session_id, event_type, offer_id, assignment_id, channel
FROM default.offer_engagement_queue;
