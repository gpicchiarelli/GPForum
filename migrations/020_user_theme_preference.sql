BEGIN;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS preferred_theme text NOT NULL DEFAULT 'default',
    ADD CONSTRAINT users_preferred_theme_check CHECK (preferred_theme IN ('default', 'dark', 'high_contrast'));

COMMIT;
