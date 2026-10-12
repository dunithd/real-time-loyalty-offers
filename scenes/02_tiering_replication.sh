#!/usr/bin/env bash
# Scene 2:40 — replication to the lakehouse. The system-of-record tables are
# analytics-replicated to Iceberg by PGAA — no pipeline, no second copy to
# maintain. Show PGAA's view of what is landing in the catalog.
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

say "PGAA replicates the system-of-record tables into Iceberg — declaratively, no pipeline."

run "psql -d kestrel -c 'SELECT ... FROM pgaa.list_analytics_tables()'" -- \
  docker exec -i kestrel-pgd bash -c "PGOPTIONS='-c client_min_messages=error' /usr/lib/edb-pge/17/bin/psql -U postgres -d kestrel -P pager=off -c \"SELECT table_name, replication_status, catalog_namespace FROM pgaa.list_analytics_tables() WHERE schema_name='kestrel_core' ORDER BY table_name;\""
