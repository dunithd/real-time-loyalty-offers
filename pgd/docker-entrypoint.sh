#!/bin/bash
#
# Bring up a single-node PGD cluster with PGAA configured to write to an external
# Lakekeeper catalog. Adapted from the Voltline reference; the logic is
# config-driven (reads /config/demo-config.toml) so Kestrel naming is picked up
# automatically.
#
# Order matters:
#   1. pgd node setup          creates PGDATA and the node group (first boot only)
#   2. PGAA GUCs               appended to postgresql.conf before the server runs
#   3. CREATE EXTENSION pgaa
#   4. resolve warehouse UUID  from Lakekeeper's management API
#   5. pgaa.add_catalog        wrapped in bdr.replicate_ddl_command
#   6. analytics_write_catalog set on the node group
#   7. pgaa.attach_catalog
#
# Steps 5/6 are BDR calls, not plain PGAA calls: the Postgres -> Iceberg write
# path is implemented on top of BDR, which is why this demo runs PGD (one node,
# one container) rather than plain Postgres.

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/config/demo-config.toml}"
PGBIN="${PGBIN:-/usr/lib/edb-pge/17/bin}"

# The healthcheck gates on this marker, not on pg_isready alone. Postgres accepts
# connections long before the catalog is registered and attached, and anything
# that connects in that window gets a database that looks fine and silently fails
# to replicate. The marker is removed on every start so a restart cannot report
# ready using the previous run's state.
READY_MARKER=/tmp/pgaa-ready
rm -f "$READY_MARKER"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

parse_config() {
    python3 -c "
import tomli, sys
with open('$CONFIG_FILE', 'rb') as f:
    config = tomli.load(f)
value = config
for k in '$1'.split('.'):
    value = value[k]
print(value)
"
}

psql_demo() {
    PGPASSWORD="$POSTGRES_PASSWORD" "$PGBIN/psql" \
        -v ON_ERROR_STOP=1 -h localhost -U postgres -d "$PG_DATABASE" "$@"
}

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    log_error "demo-config.toml must be mounted at /config/demo-config.toml"
    exit 1
fi
log_info "Using configuration file: $CONFIG_FILE"

CATALOG_NAME=$(parse_config "catalog.name")
CATALOG_TYPE=$(parse_config "catalog.type")
CATALOG_URL=$(parse_config "catalog.url")
CATALOG_WAREHOUSE_NAME=$(parse_config "catalog.warehouse_name")
NODE_GROUP=$(parse_config "database.transactional.node_group")
PG_DATABASE=$(parse_config "database.transactional.database")
ANALYTICS_PATH=$(parse_config "database.transactional.analytics_path")

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-secret}"
export PGPASSWORD="$POSTGRES_PASSWORD"

log_info "Catalog:    $CATALOG_NAME ($CATALOG_TYPE) at $CATALOG_URL"
log_info "Warehouse:  $CATALOG_WAREHOUSE_NAME"
log_info "Node group: $NODE_GROUP"
log_info "Database:   $PG_DATABASE"

# ---------------------------------------------------------------------------
# 1. Initialise the PGD node, or restart an existing one.
# ---------------------------------------------------------------------------
if [ ! -f "/var/lib/postgresql/db/PG_VERSION" ]; then
    log_info "Initialising single-node PGD cluster (node db1, group $NODE_GROUP)..."

    "$PGBIN/pgd" node db1 setup \
        --dsn "host=0.0.0.0 dbname=$PG_DATABASE user=postgres password=${POSTGRES_PASSWORD}" \
        --pgdata /var/lib/postgresql/db \
        --log-file /var/lib/postgresql/logfile \
        --group-name "$NODE_GROUP"

    # PGAA configuration. The timing GUCs are tuned well below their defaults so
    # that replication into Iceberg is observable inside a live demo rather than
    # after a 30-60 second wait.
    cat >> /var/lib/postgresql/db/postgresql.conf <<EOF

# --- PGAA (added by docker-entrypoint.sh) ---
pgfs.allowed_local_fs_paths = '$ANALYTICS_PATH'
pgaa.autostart_seafowl_port = 5445
pgaa.seafowl_url = 'http://localhost:5445'
listen_addresses = '*'

# Force a flush to Iceberg within 2s of a write. THE knob for the "watch it land"
# stage beat: at the default 5s, end-to-end PGD -> Iceberg visibility measured
# ~11-17s (over the 10s budget); at 2s it measures ~7-9s. See DESIGN_NOTES.md.
pgaa.max_replication_lag_s = 2

# Create tiered-table partitions on a 1s wakeup instead of every 5 minutes.
bdr.taskmgr_nap_time = 1000

# Statistics for every table, so the analytics engine can plan.
edb.collect_table_statistics = all
EOF

    echo "host    all             all             0.0.0.0/0               md5" \
        >> /var/lib/postgresql/db/pg_hba.conf

    log_info "PGD cluster initialised"
else
    log_info "Existing cluster found, starting PostgreSQL..."
    "$PGBIN/pg_ctl" -D /var/lib/postgresql/db -l /var/lib/postgresql/logfile start
fi

# ---------------------------------------------------------------------------
# 2. Wait for the server.
# ---------------------------------------------------------------------------
log_info "Waiting for PostgreSQL..."
for i in $(seq 1 60); do
    if "$PGBIN/pg_isready" -h localhost -U postgres -d "$PG_DATABASE" >/dev/null 2>&1; then
        log_info "PostgreSQL is ready"
        break
    fi
    if [ "$i" -eq 60 ]; then
        log_error "PostgreSQL did not become ready within 60s"
        tail -50 /var/lib/postgresql/logfile || true
        exit 1
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# 3. PGAA extension.
# ---------------------------------------------------------------------------
log_info "Ensuring pgaa extension..."
psql_demo -c "CREATE EXTENSION IF NOT EXISTS pgaa CASCADE;"

# ---------------------------------------------------------------------------
# 4. Resolve the warehouse name to Lakekeeper's internal UUID.
#
# PGAA wants the UUID; demo-config.toml carries the human-readable name. The
# management API lives at the catalog URL with the /catalog suffix stripped.
# Retried: initialwarehouse completing does not guarantee Lakekeeper is still
# answering by the time this container gets here.
# ---------------------------------------------------------------------------
BASE_URL="${CATALOG_URL%/catalog}"
log_info "Resolving warehouse '$CATALOG_WAREHOUSE_NAME' via ${BASE_URL}/management/v1/warehouse ..."

WAREHOUSE_ID=""
for attempt in $(seq 1 30); do
    WAREHOUSE_LIST=$(curl -sS --max-time 10 "${BASE_URL}/management/v1/warehouse" 2>/dev/null || echo '')
    if [ -n "$WAREHOUSE_LIST" ]; then
        WAREHOUSE_ID=$(printf '%s' "$WAREHOUSE_LIST" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in data.get('warehouses', []):
    if w.get('name') == '$CATALOG_WAREHOUSE_NAME':
        print(w['id'])
        break
" 2>/dev/null || echo '')
    fi
    if [ -n "$WAREHOUSE_ID" ]; then
        break
    fi
    log_warn "warehouse not available yet (attempt $attempt/30), retrying in 2s..."
    sleep 2
done

if [ -z "$WAREHOUSE_ID" ]; then
    log_error "Warehouse '$CATALOG_WAREHOUSE_NAME' not found in Lakekeeper after 60s."
    log_error "Check the catalog stack: docker compose logs initialwarehouse"
    exit 1
fi
log_info "Warehouse ID: $WAREHOUSE_ID"

# ---------------------------------------------------------------------------
# 5/6. Register the catalog and make it the default analytics write target.
#
# No object-store credentials here on purpose: the warehouse is sts-enabled, so
# Lakekeeper vends temporary S3 credentials and the catalog stays the single
# place those credentials live. warehouse_name is included alongside warehouse
# because remote executors require it.
# ---------------------------------------------------------------------------
CATALOG_EXISTS=$(psql_demo -tAc \
    "SELECT COUNT(*) FROM pgaa.list_catalogs() WHERE name = '$CATALOG_NAME';")

if [ "$CATALOG_EXISTS" = "0" ]; then
    log_info "Registering catalog $CATALOG_NAME..."
    psql_demo <<EOSQL
SELECT bdr.replicate_ddl_command(\$\$
  SELECT pgaa.add_catalog(
    '$CATALOG_NAME',
    '$CATALOG_TYPE',
    '{
      "url": "$CATALOG_URL",
      "warehouse": "$WAREHOUSE_ID",
      "warehouse_name": "$CATALOG_WAREHOUSE_NAME"
    }'
  );
\$\$);
EOSQL

    log_info "Setting $CATALOG_NAME as the default analytics write catalog..."
    psql_demo -c \
        "SELECT bdr.alter_node_group_option('$NODE_GROUP', 'analytics_write_catalog', '$CATALOG_NAME');"

    log_info "Catalog registration complete"
else
    log_info "Catalog $CATALOG_NAME already registered"
fi

# ---------------------------------------------------------------------------
# 7. Attach the catalog.
#
# add_catalog only records the catalog; a newly registered or freshly restarted
# catalog sits in state 'detached'. Enabling analytics replication while detached
# returns successfully but registers nothing. Attaching here means the database
# is usable the moment the healthcheck passes.
# ---------------------------------------------------------------------------
log_info "Attaching catalog $CATALOG_NAME..."
if psql_demo -c "SET statement_timeout = '120s'; SELECT pgaa.attach_catalog('$CATALOG_NAME');"; then
    CATALOG_STATUS=$(psql_demo -tAc \
        "SELECT status FROM pgaa.list_catalogs() WHERE name = '$CATALOG_NAME';")
    log_info "Catalog $CATALOG_NAME status: $CATALOG_STATUS"
    if [ "$CATALOG_STATUS" != "attached" ]; then
        log_warn "Catalog is '$CATALOG_STATUS', not 'attached'. Replication will"
        log_warn "silently register nothing until it attaches. Retry with:"
        log_warn "  make psql -> SELECT pgaa.attach_catalog('$CATALOG_NAME');"
    fi
else
    log_warn "attach_catalog failed; see the log above. The server is still up."
fi

touch "$READY_MARKER"
log_info "Ready. PGAA is configured to write to $CATALOG_NAME."
log_info "Follow the server log with: docker compose logs -f pgd"

# pgd node setup starts the server itself; PID 1 just has to stay alive.
exec tail -f /var/lib/postgresql/logfile
