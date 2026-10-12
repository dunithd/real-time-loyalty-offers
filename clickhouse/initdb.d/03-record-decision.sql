-- The single ClickHouse write path: record a decision into PGD. This is the
-- standard PostgreSQL table engine (not the Iceberg catalog, which is read-only).
-- INSERTs here go straight into kestrel_core.offer_assignments in PGD over libpq;
-- PGD partition-routes by assigned_at and PGAA replicates the new row to Iceberg.
--
-- Connection is lazy — defined at init even though PGD may not be up yet; it
-- connects when first queried. assignment_id is minted in ClickHouse with
-- generateUUIDv4() at insert time (see queries/record_decision.sql).
CREATE TABLE IF NOT EXISTS default.pgd_offer_assignments
(
    assignment_id   UUID,
    assigned_at     DateTime64(6),
    member_id       Int32,
    offer_id        Int32,
    session_id      String,
    slot            String,
    region          String,
    is_control      Bool,
    score           Float64,
    decision_reason String,
    expires_at      DateTime64(6),
    status          String
)
ENGINE = PostgreSQL('pgd:5432', 'kestrel', 'offer_assignments', 'postgres', 'secret', 'kestrel_core');
