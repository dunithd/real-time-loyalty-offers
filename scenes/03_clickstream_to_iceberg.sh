#!/usr/bin/env bash
# Scene 3:40 — clickstream to Iceberg. Show the Kafka topic carrying JSON events
# and the Iceberg row count growing across two reads (commit interval ~10s).
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

say "App & web clickstream flows as JSON through Kafka, and the Iceberg sink lands it."

run "kafka-console-consumer --topic kestrel.digital.events --max-messages 3" -- \
  docker exec -i kestrel-kafka /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server kafka:9092 --topic kestrel.digital.events --max-messages 3 --timeout-ms 15000

say "Row count in Iceberg (kestrel_events.digital_events), read twice ~12s apart:"
run "count #1" -- docker exec -i kestrel-clickhouse clickhouse-client -q \
  "SELECT count() FROM iceberg_catalog.\`kestrel_events.digital_events\`"
sleep 12
run "count #2 (grown)" -- docker exec -i kestrel-clickhouse clickhouse-client -q \
  "SELECT count() FROM iceberg_catalog.\`kestrel_events.digital_events\`"
