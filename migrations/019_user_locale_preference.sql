BEGIN;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS preferred_locale text NOT NULL DEFAULT 'en',
    ADD CONSTRAINT users_preferred_locale_check CHECK (preferred_locale IN ('en', 'it'));

COMMIT;
