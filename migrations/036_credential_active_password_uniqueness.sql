BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_credentials_active_password_unique
    ON credentials (user_id)
    WHERE revoked_at IS NULL AND type = 'password';

COMMIT;
