-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

-- Near-term monthly range partitions for the append-only partitioned tables.
-- event_log, audit_log and notifications are PARTITION BY RANGE (created_at)
-- (migrations 002 and 003) but only their DEFAULT partitions existed, so a
-- fresh install wrote every row into one heap. Bounds are explicit UTC month
-- boundaries; CREATE TABLE IF NOT EXISTS keeps re-application safe.
-- On an installation whose DEFAULT partition already holds rows inside one of
-- these ranges PostgreSQL refuses the CREATE and this migration aborts. Run
-- bin/gpforum-partition-maintenance --plan, apply the printed remediation in a
-- maintenance window (it takes ACCESS EXCLUSIVE locks), then re-apply.
-- bin/gpforum-partition-maintenance --apply keeps the window ahead after this.

BEGIN;

CREATE TABLE IF NOT EXISTS audit_log_2026_09
    PARTITION OF audit_log
    FOR VALUES FROM (TIMESTAMPTZ '2026-09-01 00:00:00+00')
    TO (TIMESTAMPTZ '2026-10-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS audit_log_2026_10
    PARTITION OF audit_log
    FOR VALUES FROM (TIMESTAMPTZ '2026-10-01 00:00:00+00')
    TO (TIMESTAMPTZ '2026-11-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS audit_log_2026_11
    PARTITION OF audit_log
    FOR VALUES FROM (TIMESTAMPTZ '2026-11-01 00:00:00+00')
    TO (TIMESTAMPTZ '2026-12-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS audit_log_2026_12
    PARTITION OF audit_log
    FOR VALUES FROM (TIMESTAMPTZ '2026-12-01 00:00:00+00')
    TO (TIMESTAMPTZ '2027-01-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS event_log_2026_09
    PARTITION OF event_log
    FOR VALUES FROM (TIMESTAMPTZ '2026-09-01 00:00:00+00')
    TO (TIMESTAMPTZ '2026-10-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS event_log_2026_10
    PARTITION OF event_log
    FOR VALUES FROM (TIMESTAMPTZ '2026-10-01 00:00:00+00')
    TO (TIMESTAMPTZ '2026-11-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS event_log_2026_11
    PARTITION OF event_log
    FOR VALUES FROM (TIMESTAMPTZ '2026-11-01 00:00:00+00')
    TO (TIMESTAMPTZ '2026-12-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS event_log_2026_12
    PARTITION OF event_log
    FOR VALUES FROM (TIMESTAMPTZ '2026-12-01 00:00:00+00')
    TO (TIMESTAMPTZ '2027-01-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS notifications_2026_09
    PARTITION OF notifications
    FOR VALUES FROM (TIMESTAMPTZ '2026-09-01 00:00:00+00')
    TO (TIMESTAMPTZ '2026-10-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS notifications_2026_10
    PARTITION OF notifications
    FOR VALUES FROM (TIMESTAMPTZ '2026-10-01 00:00:00+00')
    TO (TIMESTAMPTZ '2026-11-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS notifications_2026_11
    PARTITION OF notifications
    FOR VALUES FROM (TIMESTAMPTZ '2026-11-01 00:00:00+00')
    TO (TIMESTAMPTZ '2026-12-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS notifications_2026_12
    PARTITION OF notifications
    FOR VALUES FROM (TIMESTAMPTZ '2026-12-01 00:00:00+00')
    TO (TIMESTAMPTZ '2027-01-01 00:00:00+00');

INSERT INTO partition_registry (table_name, partition_name, range_start, range_end, state)
VALUES
    ('audit_log', 'audit_log_2026_09', TIMESTAMPTZ '2026-09-01 00:00:00+00', TIMESTAMPTZ '2026-10-01 00:00:00+00', 'created'),
    ('audit_log', 'audit_log_2026_10', TIMESTAMPTZ '2026-10-01 00:00:00+00', TIMESTAMPTZ '2026-11-01 00:00:00+00', 'created'),
    ('audit_log', 'audit_log_2026_11', TIMESTAMPTZ '2026-11-01 00:00:00+00', TIMESTAMPTZ '2026-12-01 00:00:00+00', 'created'),
    ('audit_log', 'audit_log_2026_12', TIMESTAMPTZ '2026-12-01 00:00:00+00', TIMESTAMPTZ '2027-01-01 00:00:00+00', 'created'),
    ('event_log', 'event_log_2026_09', TIMESTAMPTZ '2026-09-01 00:00:00+00', TIMESTAMPTZ '2026-10-01 00:00:00+00', 'created'),
    ('event_log', 'event_log_2026_10', TIMESTAMPTZ '2026-10-01 00:00:00+00', TIMESTAMPTZ '2026-11-01 00:00:00+00', 'created'),
    ('event_log', 'event_log_2026_11', TIMESTAMPTZ '2026-11-01 00:00:00+00', TIMESTAMPTZ '2026-12-01 00:00:00+00', 'created'),
    ('event_log', 'event_log_2026_12', TIMESTAMPTZ '2026-12-01 00:00:00+00', TIMESTAMPTZ '2027-01-01 00:00:00+00', 'created'),
    ('notifications', 'notifications_2026_09', TIMESTAMPTZ '2026-09-01 00:00:00+00', TIMESTAMPTZ '2026-10-01 00:00:00+00', 'created'),
    ('notifications', 'notifications_2026_10', TIMESTAMPTZ '2026-10-01 00:00:00+00', TIMESTAMPTZ '2026-11-01 00:00:00+00', 'created'),
    ('notifications', 'notifications_2026_11', TIMESTAMPTZ '2026-11-01 00:00:00+00', TIMESTAMPTZ '2026-12-01 00:00:00+00', 'created'),
    ('notifications', 'notifications_2026_12', TIMESTAMPTZ '2026-12-01 00:00:00+00', TIMESTAMPTZ '2027-01-01 00:00:00+00', 'created')
ON CONFLICT (table_name, partition_name) DO NOTHING;

COMMIT;
