-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_reputation_events_source_unique
    ON reputation_events (user_id, source_type, source_id)
    WHERE source_id IS NOT NULL;

COMMIT;
