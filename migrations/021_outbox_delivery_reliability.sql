-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

ALTER TABLE outbox_messages
    ADD COLUMN IF NOT EXISTS failure_type text;

ALTER TABLE dead_letters
    ADD COLUMN IF NOT EXISTS failure_type text NOT NULL DEFAULT 'transient';

CREATE INDEX IF NOT EXISTS idx_outbox_messages_retry_backlog
    ON outbox_messages (failure_type, next_attempt_at, created_at)
    WHERE status = 'failed';

CREATE INDEX IF NOT EXISTS idx_dead_letters_failure_type
    ON dead_letters (failure_type, last_failed_at);

COMMIT;
