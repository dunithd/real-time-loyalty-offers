-- Deliver — the redemption transaction for the hero (member 100042).
--
-- One atomic transaction (a DO block runs in its own transaction):
--   SELECT ... FOR UPDATE on the assignment -> check it is assigned, not expired,
--   not control -> insert the order and line -> insert the redemption -> insert
--   the points-ledger entry -> UPDATE the assignment to 'redeemed' -> COMMIT.
--
-- "Redeem once" is enforced here (lock + status check), not by a unique
-- constraint: tiered/partitioned tables can't carry a unique constraint that
-- excludes the partition column. Ids are app-generated (max()+1) — no sequences
-- on tiered tables. The new rows replicate to Iceberg within max_replication_lag_s.
DO $$
DECLARE
    v_a        kestrel_core.offer_assignments%ROWTYPE;
    v_store    int;
    v_product  int;
    v_disc_pct numeric;
    v_order_id bigint;
    v_red_id   bigint;
    v_entry_id bigint;
    v_basket   numeric := 14.50;
    v_discount numeric;
BEGIN
    -- Lock the hero's live, shown (non-control) assignment.
    SELECT * INTO v_a
    FROM kestrel_core.offer_assignments
    WHERE member_id = 100042 AND status = 'assigned' AND is_control = false
    ORDER BY assigned_at DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no redeemable assignment for hero member 100042';
    END IF;
    IF v_a.expires_at IS NOT NULL AND v_a.expires_at < now() THEN
        RAISE EXCEPTION 'assignment % has expired', v_a.assignment_id;
    END IF;

    SELECT home_store_id INTO v_store FROM kestrel_core.members WHERE member_id = 100042;
    SELECT product_id INTO v_product FROM kestrel_core.products WHERE category_id = 7 ORDER BY product_id LIMIT 1;
    SELECT discount_pct INTO v_disc_pct FROM kestrel_core.offers WHERE offer_id = v_a.offer_id;
    v_discount := round(v_basket * v_disc_pct / 100.0, 2);

    SELECT coalesce(max(order_id), 0) + 1 INTO v_order_id FROM kestrel_core.orders;
    INSERT INTO kestrel_core.orders (order_id, ordered_at, member_id, store_id, channel, total)
        VALUES (v_order_id, now(), 100042, v_store, 'app', v_basket);
    INSERT INTO kestrel_core.order_lines (order_id, ordered_at, line_no, product_id, category_id, qty, amount)
        VALUES (v_order_id, now(), 1, v_product, 7, 1, v_basket);

    SELECT coalesce(max(redemption_id), 0) + 1 INTO v_red_id FROM kestrel_core.offer_redemptions;
    INSERT INTO kestrel_core.offer_redemptions
        (redemption_id, redeemed_at, assignment_id, order_id, member_id, offer_id, discount_amount)
        VALUES (v_red_id, now(), v_a.assignment_id, v_order_id, 100042, v_a.offer_id, v_discount);

    SELECT coalesce(max(entry_id), 0) + 1 INTO v_entry_id FROM kestrel_core.points_ledger;
    INSERT INTO kestrel_core.points_ledger (entry_id, posted_at, member_id, order_id, points, kind)
        VALUES (v_entry_id, now(), 100042, v_order_id, floor(v_basket)::int, 'earn');

    UPDATE kestrel_core.offer_assignments
        SET status = 'redeemed'
        WHERE assignment_id = v_a.assignment_id AND assigned_at = v_a.assigned_at;

    RAISE NOTICE 'REDEEMED assignment=% order=% discount=% points=%',
        v_a.assignment_id, v_order_id, v_discount, floor(v_basket)::int;
END $$;
