-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

-- Realtime fallback polling scans done outbox rows in deterministic batches.
CREATE INDEX IF NOT EXISTS idx_outbox_messages_realtime_poll
    ON outbox_messages (status, next_attempt_at, created_at, outbox_id)
    WHERE status = 'done';
