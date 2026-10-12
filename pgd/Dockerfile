# PGD 6 + PGAA on Postgres Extended 17, built from the EDB package repositories.
#
# Reproducible path: given a valid EDB subscription token, it builds on any
# machine. A cold build is slow on Apple Silicon because the EDB packages are
# amd64 only and run under emulation.
#
# The token is a BuildKit secret, not a build ARG, so it does not end up in the
# image history. The Makefile builds with DOCKER_BUILDKIT=1.

FROM ubuntu:24.04

ARG PLATFORM=linux/amd64

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      lsb-release \
      python3 \
      python3-pip \
      python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Three EDB repositories and the packages, in ONE layer. Repo setup and the
# install must share a RUN: in separate layers the second apt-get update runs
# without the just-added EDB sources and the packages are "Unable to locate"
# (verified against this token's repos — the package names below are correct).
#   postgres_distributed — PGD 6 BDR plugin (edb-pgd6-expanded-pgextended17)
#   enterprise           — Postgres Extended 17 (edb-postgresextended-17)
#   dev                  — PGAA (edb-postgresextended-17-pgaa)
RUN --mount=type=secret,id=edb_token,required=true \
    set -eu; \
    EDB_SUBSCRIPTION_TOKEN="$(cat /run/secrets/edb_token)"; \
    for repo in postgres_distributed enterprise dev; do \
      curl -1sLf "https://downloads.enterprisedb.com/${EDB_SUBSCRIPTION_TOKEN}/${repo}/setup.deb.sh" | bash; \
    done; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      edb-pgd6-expanded-pgextended17 \
      edb-postgresextended-17-pgaa; \
    rm -rf /var/lib/apt/lists/*

# The entrypoint parses demo-config.toml; psycopg2 is here so the container can
# run ad-hoc checks without installing anything.
RUN python3 -m pip install --no-cache-dir --break-system-packages \
      tomli \
      psycopg2-binary

# PGDATA lives on a named volume; pgd-analytics is PGAA's local filesystem
# fallback location and must be on the pgfs allow-list.
RUN mkdir -p /var/lib/postgresql/db /var/lib/postgresql/pgd-analytics \
    && chown -R postgres:postgres /var/lib/postgresql

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV PGDATA=/var/lib/postgresql/db \
    POSTGRES_PASSWORD=secret \
    PATH="/usr/lib/edb-pge/17/bin:${PATH}"

# 5432 Postgres, 6432 PGD proxy read-write, 6433 PGD proxy read-only.
EXPOSE 5432 6432 6433

USER postgres
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
