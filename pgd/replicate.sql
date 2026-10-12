-- Kestrel — replicate the system-of-record tables into Iceberg.
--
-- Run AFTER the seed (setup_core.py) so each table offloads its existing rows in
-- one shot. The catalog must already be attached (the entrypoint attaches it;
-- setup_core re-attaches defensively).
--
-- DESIGN DECISION (2026-10-05): plain analytics replication for ALL tables, the
-- Voltline model. We originally tiered the five fact tables with
-- pgaa.convert_to_tiered_table(enable_replication := true), but the initial
-- offload under amd64 emulation created ~36 monthly partition tables per fact
-- table (148 Iceberg tables total) and moved rows far too slowly to be
-- demo-reliable — after 5 minutes only 4 of 148 partitions had offloaded.
-- enable_analytics_replication mirrors each table to ONE clean Iceberg table,
-- offloads the seeded history in a single pass, and replicates subsequent inserts
-- (the live decision + redemption) within pgaa.max_replication_lag_s (2s). This
-- keeps the "watch it land" beats and the downstream ClickHouse/WHPG/DuckDB reads
-- simple. See DESIGN_NOTES.md. (The verified tiered-table syntax is kept in git
-- history if we want to showcase tiering on a single small table later.)

CALL pgaa.enable_analytics_replication('kestrel_core.categories',        true);
CALL pgaa.enable_analytics_replication('kestrel_core.stores',            true);
CALL pgaa.enable_analytics_replication('kestrel_core.products',          true);
CALL pgaa.enable_analytics_replication('kestrel_core.members',           true);
CALL pgaa.enable_analytics_replication('kestrel_core.offers',            true);
CALL pgaa.enable_analytics_replication('kestrel_core.orders',            true);
CALL pgaa.enable_analytics_replication('kestrel_core.order_lines',       true);
CALL pgaa.enable_analytics_replication('kestrel_core.points_ledger',     true);
CALL pgaa.enable_analytics_replication('kestrel_core.offer_assignments', true);
CALL pgaa.enable_analytics_replication('kestrel_core.offer_redemptions', true);
