-- GPForum attachment scan engine.
--
-- ADR 0108: uploads are scanned by the free antivirus the operating system
-- installed. A verdict is only as good as what produced it, so the row now
-- records that too: scan_engine names the engine and signature database that
-- decided ("ClamAV 1.4.1/27400"), or 'format-check' when the operator turned
-- scanning off and only the media type was verified. scan_signature is the
-- name of what an antivirus found, for an infected file. Both are NULL for a
-- row scanned before this migration: its verdict came from the format check
-- alone, and the column says nothing it does not know. Those rows stay
-- served; the scheduled attachment_backfill job puts them through the
-- antivirus once one is configured, quarantining what it finds.
--
-- ADD COLUMN with no default, or a constant one, is a catalog change; it does
-- not rewrite attachments. The index build takes a SHARE lock on attachments for its
-- duration.

BEGIN;

ALTER TABLE attachments ADD COLUMN IF NOT EXISTS scan_engine text;
ALTER TABLE attachments ADD COLUMN IF NOT EXISTS scan_signature text;

-- Failed attempts by the scheduled rescan and backfill, and the last error.
-- Both jobs take files with the fewest attempts first, so files that keep
-- failing -- an unreadable object, one past clamd's StreamMaxLength -- sink
-- behind the rest instead of being picked, and failing, every hour.
ALTER TABLE attachments
    ADD COLUMN IF NOT EXISTS scan_attempts integer NOT NULL DEFAULT 0;
ALTER TABLE attachments ADD COLUMN IF NOT EXISTS scan_error text;

-- The hourly rescan asks for uploads still pending, oldest first. Pending rows
-- exist only while an antivirus could not answer, so the index is tiny and is
-- written only as a verdict clears it.
-- The backfill asks for files served on a format check alone -- uploaded
-- before this migration, or while scanning was off -- to put them through the
-- antivirus. The index empties as they are confirmed.
CREATE INDEX IF NOT EXISTS idx_attachments_format_checked
    ON attachments (scan_attempts, created_at, attachment_id)
    WHERE scan_status = 'clean'
      AND deleted_at IS NULL
      AND (scan_engine IS NULL OR scan_engine = 'format-check');

CREATE INDEX IF NOT EXISTS idx_attachments_pending_scan
    ON attachments (scan_attempts, uploaded_at, attachment_id)
    WHERE scan_status = 'pending';

COMMIT;
