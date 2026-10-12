#!/bin/bash
#
# Start a distributed Kafka Connect worker.
#
# The apache/kafka image ships connect-distributed.sh but no generated worker
# config, so this writes one from environment variables. Everything that has to
# be 1 on a single broker (the three internal topics' replication factors) is set
# here rather than left to the shipped defaults, which assume 3.
#
# Kestrel events are plain JSON. The worker-level default converters below are
# JsonConverter with schemas DISABLED — the generator emits flat JSON, ClickHouse
# reads the same flat JSON as JSONEachRow, and the Iceberg sink writes into
# PRE-CREATED Iceberg tables (iceberg.tables.auto-create-enabled=false in the
# connector config), so no embedded per-message schema is needed. See
# DESIGN_NOTES.md for why flat-JSON + pre-created tables (not schema+payload
# envelopes) was chosen.

set -euo pipefail

BOOTSTRAP="${CONNECT_BOOTSTRAP_SERVERS:-kafka:9092}"
GROUP_ID="${CONNECT_GROUP_ID:-kestrel-connect}"
REST_PORT="${CONNECT_REST_PORT:-8083}"
REST_ADVERTISED_HOST="${CONNECT_REST_ADVERTISED_HOST_NAME:-connect}"
PLUGIN_PATH="${CONNECT_PLUGIN_PATH:-/opt/kafka/plugins}"

CONFIG=/tmp/connect-distributed.properties

cat > "$CONFIG" <<EOF
bootstrap.servers=${BOOTSTRAP}
group.id=${GROUP_ID}

# Plain JSON, no registry. Keys are strings (member_id/session_id); values are
# schemaless JSON. The Iceberg sink maps JSON fields by name into the
# pre-created table's columns.
key.converter=org.apache.kafka.connect.storage.StringConverter
value.converter=org.apache.kafka.connect.json.JsonConverter
value.converter.schemas.enable=false

# Single broker: all three internal topics must be replication factor 1.
offset.storage.topic=${GROUP_ID}-offsets
offset.storage.replication.factor=1
offset.storage.partitions=25
config.storage.topic=${GROUP_ID}-configs
config.storage.replication.factor=1
config.storage.partitions=1
status.storage.topic=${GROUP_ID}-status
status.storage.replication.factor=1
status.storage.partitions=5

offset.flush.interval.ms=10000

listeners=http://0.0.0.0:${REST_PORT}
rest.advertised.host.name=${REST_ADVERTISED_HOST}
rest.advertised.port=${REST_PORT}

plugin.path=${PLUGIN_PATH}
EOF

echo "--- connect-distributed.properties ---"
cat "$CONFIG"
echo "--------------------------------------"

exec /opt/kafka/bin/connect-distributed.sh "$CONFIG"
