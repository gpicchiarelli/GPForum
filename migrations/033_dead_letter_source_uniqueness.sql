BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_dead_letters_source_unique
    ON dead_letters (source_table, source_id);

COMMIT;
