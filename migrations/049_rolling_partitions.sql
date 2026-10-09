-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

-- Monthly partitions are computed from the date from here on (ADR 0113).
-- Migration 038 named September to December 2026 outright, so an
-- installation migrated later got four months already gone and none for the
-- month it was in. bin/gpforum-migrate --apply now creates the current month
-- and the lookahead after the migrations, and the daily
-- gpforum-partition-maintenance timer keeps the window ahead.
--
-- This drops what such an installation was left with: every month partition
-- of audit_log, event_log and notifications whose range ended before the
-- current UTC month and that holds no row, with its partition_registry row.
-- An empty past month only lengthens every plan that does not prune it. A
-- partition holding rows is left where it is, whatever its age, and named in
-- a NOTICE: retention is the owner's call (ADR 0113), not a migration's.
-- Nothing here names a month, so the migration means the same whenever it
-- runs.
--
-- Locking. DROP TABLE of a partition needs ACCESS EXCLUSIVE on its parent.
-- A partition is first checked for rows without that lock, so a parent whose
-- past months all hold rows (the owner's September) is never locked at all.
-- Each parent is then done in a transaction of its own, which locks that
-- parent and no other: holding one parent's ACCESS EXCLUSIVE while waiting
-- for the next is what lets an application transaction that writes
-- event_log, then audit_log, deadlock with it. Under the lock the partition
-- is checked again, so no row can arrive between the check and the drop.
-- lock_timeout bounds each wait; past it the migration fails, the parents
-- done before stay done, and it is safe to run again, as every step is.
--
-- gpforum.partition_cutoff, when a session sets it, replaces the current
-- month as the cut-off, so a test can replay this at another date
-- (t/integration/postgres-partition-maintenance.t). Nothing else sets it.

CREATE OR REPLACE FUNCTION pg_temp.gpforum_drop_empty_past_months(
    parent_name text
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    cutoff timestamptz := coalesce(
        nullif(current_setting('gpforum.partition_cutoff', true), '')::timestamptz,
        date_trunc('month', now(), 'UTC'));
    month record;
    holds_rows boolean;
    empty_months text[] := '{}';
    child_name text;
BEGIN
    FOR month IN
        SELECT child.relname AS child_name
        FROM pg_inherits AS inheritance
        JOIN pg_class AS parent ON parent.oid = inheritance.inhparent
        JOIN pg_class AS child ON child.oid = inheritance.inhrelid
        JOIN pg_namespace AS space ON space.oid = parent.relnamespace
        WHERE space.nspname = current_schema()
          AND parent.relname = parent_name
          AND child.relname ~ ('^' || parent.relname || '_[0-9]{4}_(0[1-9]|1[0-2])$')
          AND substring(pg_get_expr(child.relpartbound, child.oid)
                FROM 'TO \(''([^'']+)''\)')::timestamptz <= cutoff
        ORDER BY child.relname
    LOOP
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM ONLY %I)', month.child_name)
            INTO holds_rows;
        IF holds_rows THEN
            RAISE NOTICE 'migration 049 keeps %: it holds rows', month.child_name;
        ELSE
            empty_months := empty_months || month.child_name::text;
        END IF;
    END LOOP;

    IF cardinality(empty_months) = 0 THEN
        RETURN;
    END IF;

    EXECUTE format('LOCK TABLE %I IN ACCESS EXCLUSIVE MODE', parent_name);
    FOREACH child_name IN ARRAY empty_months LOOP
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM ONLY %I)', child_name)
            INTO holds_rows;
        IF holds_rows THEN
            RAISE NOTICE 'migration 049 keeps %: it holds rows', child_name;
            CONTINUE;
        END IF;
        EXECUTE format('DROP TABLE %I', child_name);
        DELETE FROM partition_registry
        WHERE table_name = parent_name
          AND partition_name = child_name;
    END LOOP;
END
$$;

BEGIN;
SET LOCAL lock_timeout = '5s';
SELECT pg_temp.gpforum_drop_empty_past_months('audit_log');
COMMIT;

BEGIN;
SET LOCAL lock_timeout = '5s';
SELECT pg_temp.gpforum_drop_empty_past_months('event_log');
COMMIT;

BEGIN;
SET LOCAL lock_timeout = '5s';
SELECT pg_temp.gpforum_drop_empty_past_months('notifications');
COMMIT;

DROP FUNCTION pg_temp.gpforum_drop_empty_past_months(text);
