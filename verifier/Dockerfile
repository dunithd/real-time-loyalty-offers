# The verifier / tools image: a small Python box that seeds PGD, pre-creates the
# Iceberg event tables, drives setup, and runs row-count assertions. Read-only
# against the catalog except for creating the (empty) event tables via pyiceberg.
FROM python:3.12-slim

RUN pip install --no-cache-dir \
      "pyiceberg[s3fs]==0.8.1" \
      pyarrow \
      psycopg2-binary \
      duckdb \
      kafka-python \
      rich \
      tomli

# Verifier scripts live in /app; the shared universe module is mounted at /common
# and demo-config.toml at /config (see docker-compose.yml).
WORKDIR /app
COPY . /app
ENV PYTHONPATH=/app:/common \
    CONFIG_FILE=/config/demo-config.toml \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["python"]
