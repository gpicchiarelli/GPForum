-- GPForum audit chain tip index.
--
-- Infrastructure::EventRecorder reads the head of the hash chain on EVERY
-- auditable write, with
--
--   SELECT ... FROM audit_log ORDER BY created_at DESC, audit_id DESC LIMIT 1
--
-- and it does so while holding pg_advisory_xact_lock, so the cost is paid
-- serially by every thread creation, moderation action and privacy request.
--
-- audit_log is partitioned by created_at and carried only a BRIN index on that
-- column, which cannot answer an ORDER BY ... LIMIT. Measured against 200,000
-- rows on PostgreSQL 18, the read was a parallel sequential scan of every
-- partition followed by a top-N heapsort, touching 3,543 shared buffers. With
-- this index it is a Merge Append of per-partition index scans touching 8.
--
-- The column order matches the ORDER BY exactly, including the descending
-- direction, so the scan is a backward-free read of the first entry.
--
-- Created on the partitioned parent, which propagates to existing and future
-- partitions. Not CONCURRENTLY: PostgreSQL does not support it on a
-- partitioned parent, and the runner executes migrations inside a transaction
-- where it is illegal anyway. The build takes a SHARE lock on audit_log, which
-- blocks writes for its duration; on a large audit table run this during a
-- maintenance window.

BEGIN;

CREATE INDEX IF NOT EXISTS idx_audit_log_chain_tip
    ON audit_log (created_at DESC, audit_id DESC);

COMMIT;
