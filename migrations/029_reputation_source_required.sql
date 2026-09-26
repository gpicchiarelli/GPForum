-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

UPDATE reputation_events
SET source_id = reputation_event_id
WHERE source_id IS NULL;

ALTER TABLE reputation_events
    ALTER COLUMN source_id SET NOT NULL;

DROP INDEX IF EXISTS idx_reputation_events_source_unique;

CREATE UNIQUE INDEX IF NOT EXISTS idx_reputation_events_source_unique
    ON reputation_events (user_id, source_type, source_id);

COMMIT;
