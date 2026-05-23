BEGIN;

CREATE TABLE IF NOT EXISTS users (
    id uuid NOT NULL,
    username text NOT NULL,
    display_name text NOT NULL,
    email_normalized text NOT NULL,
    password_hash text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    trust_level integer NOT NULL DEFAULT 0,
    email_verified_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CONSTRAINT users_pkey PRIMARY KEY (id),
    CONSTRAINT users_username_key UNIQUE (username),
    CONSTRAINT users_email_normalized_key UNIQUE (email_normalized),
    CONSTRAINT users_status_check CHECK (status IN ('pending', 'active', 'suspended', 'deleted')),
    CONSTRAINT users_trust_level_check CHECK (trust_level >= 0)
);

CREATE INDEX IF NOT EXISTS idx_users_status_created_at
    ON users (status, created_at);

CREATE TABLE IF NOT EXISTS credentials (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    type text NOT NULL,
    secret_hash text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    CONSTRAINT credentials_pkey PRIMARY KEY (id),
    CONSTRAINT credentials_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT credentials_type_check CHECK (type IN ('password', 'totp', 'webauthn'))
);

CREATE INDEX IF NOT EXISTS idx_credentials_user_type_active
    ON credentials (user_id, type)
    WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS user_sessions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    session_hash text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    ip_hash text,
    user_agent_hash text,
    CONSTRAINT user_sessions_pkey PRIMARY KEY (id),
    CONSTRAINT user_sessions_session_hash_key UNIQUE (session_hash),
    CONSTRAINT user_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS idx_user_sessions_user_active
    ON user_sessions (user_id, expires_at)
    WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_user_sessions_expires_at
    ON user_sessions (expires_at);

COMMIT;
