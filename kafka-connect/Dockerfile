# Kafka Connect worker with the Apache Iceberg sink.
#
# FROM apache/kafka — the same tag the broker runs — so the Connect runtime and
# the broker cannot drift, and no Confluent base image enters the stack.
#
# No Avro/Apicurio converter: Kestrel events are plain JSON, handled by Connect's
# built-in JsonConverter. So this image carries only the Iceberg sink plugin.
#
# Two stages: the download happens in an Alpine stage (the Kafka image has no
# curl and runs non-root). The Kafka stage receives an unpacked plugin dir.

# ---------------------------------------------------------------------------
# Stage 1 — fetch and verify the plugin
# ---------------------------------------------------------------------------
FROM alpine:3.21 AS plugins

RUN apk add --no-cache curl unzip

# The Iceberg Kafka Connect sink. Not on Maven Central; Confluent Hub carries the
# Apache-2.0 distribution as a plain zip with a published checksum, which is what
# this fetches — no confluent-hub client, nothing Confluent-licensed in the image.
ARG ICEBERG_SINK_VERSION=1.9.2
ARG ICEBERG_SINK_SHA1=52dab2ff2b9659008deec803d1c1e92813c5ffa7
ARG ICEBERG_SINK_URL=https://hub-downloads.confluent.io/api/plugins/iceberg/iceberg-kafka-connect/versions/1.9.2/iceberg-iceberg-kafka-connect-1.9.2.zip

WORKDIR /build

RUN set -eu; \
    echo "Fetching Iceberg sink ${ICEBERG_SINK_VERSION} ..."; \
    curl -fsSL -o iceberg-sink.zip "${ICEBERG_SINK_URL}"; \
    echo "${ICEBERG_SINK_SHA1}  iceberg-sink.zip" | sha1sum -c -; \
    mkdir -p /plugins; \
    unzip -q iceberg-sink.zip -d /plugins; \
    rm iceberg-sink.zip

# The Confluent Hub zip was packed on a Mac and carries a __MACOSX sibling dir.
# Connect scans every directory under plugin.path, so leaving it there produces
# confusing "no plugins found" noise in the log.
RUN rm -rf /plugins/__MACOSX \
 && echo "--- plugin tree ---" && ls -1 /plugins

# ---------------------------------------------------------------------------
# Stage 2 — the worker
# ---------------------------------------------------------------------------
FROM apache/kafka:3.9.2

USER root
# The base image is Alpine and ships no curl; the healthcheck and the
# connector-registration one-shot both need it.
RUN apk add --no-cache curl
COPY --from=plugins /plugins /opt/kafka/plugins
RUN chown -R appuser:appuser /opt/kafka/plugins

COPY connect-entrypoint.sh /opt/kafka/connect-entrypoint.sh
RUN chmod 0755 /opt/kafka/connect-entrypoint.sh \
 && chown appuser:appuser /opt/kafka/connect-entrypoint.sh

USER appuser

# 8083 is the Connect REST API — the one-shot registers connectors against it
# and verify checks task state through it.
EXPOSE 8083

ENTRYPOINT ["/opt/kafka/connect-entrypoint.sh"]
