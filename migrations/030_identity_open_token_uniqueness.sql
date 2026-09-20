BEGIN;

ALTER TABLE identity_tokens
    DROP CONSTRAINT IF EXISTS identity_tokens_type_check;

ALTER TABLE identity_tokens
    ADD CONSTRAINT identity_tokens_type_check
    CHECK (
        token_type IN (
            'password_reset',
            'email_change',
            'email_verification'
        )
    );

CREATE UNIQUE INDEX IF NOT EXISTS idx_identity_tokens_open_user_type
    ON identity_tokens (user_id, token_type)
    WHERE used_at IS NULL AND user_id IS NOT NULL;

COMMIT;
