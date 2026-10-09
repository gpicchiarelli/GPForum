-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE TABLE IF NOT EXISTS identity_tokens (
    token_id uuid NOT NULL,
    user_id uuid,
    token_type text NOT NULL,
    token_hash text NOT NULL,
    email_normalized text,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    used_at timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT identity_tokens_pkey PRIMARY KEY (token_id),
    CONSTRAINT identity_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT identity_tokens_hash_key UNIQUE (token_hash),
    CONSTRAINT identity_tokens_type_check CHECK (token_type IN ('password_reset', 'email_change')),
    CONSTRAINT identity_tokens_expires_after_created_check CHECK (expires_at > created_at),
    CONSTRAINT identity_tokens_used_after_created_check CHECK (used_at IS NULL OR used_at >= created_at)
);

CREATE INDEX IF NOT EXISTS idx_identity_tokens_user_type_created
    ON identity_tokens (user_id, token_type, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_identity_tokens_active_lookup
    ON identity_tokens (token_hash, token_type, expires_at)
    WHERE used_at IS NULL;

COMMIT;
