BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_projection_generations_source_unique
    ON projection_generations (projection_name, built_from_event_id)
    WHERE built_from_event_id IS NOT NULL;

COMMIT;
