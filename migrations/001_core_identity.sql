BEGIN;

CREATE TABLE IF NOT EXISTS schema_versions (
    version text NOT NULL,
    description text NOT NULL,
    checksum text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT schema_versions_pkey PRIMARY KEY (version)
);

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

CREATE TABLE IF NOT EXISTS sessions (
    session_id uuid NOT NULL,
    user_id uuid NOT NULL,
    session_hash text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    ip_hash text,
    user_agent_hash text,
    CONSTRAINT sessions_pkey PRIMARY KEY (session_id),
    CONSTRAINT sessions_session_hash_key UNIQUE (session_hash),
    CONSTRAINT sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS idx_sessions_user_revoked_expires
    ON sessions (user_id, revoked_at, expires_at);

CREATE INDEX IF NOT EXISTS idx_sessions_lookup
    ON sessions (session_id, expires_at, revoked_at);

CREATE TABLE IF NOT EXISTS roles (
    role_id uuid NOT NULL,
    name text NOT NULL,
    description text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT roles_pkey PRIMARY KEY (role_id),
    CONSTRAINT roles_name_key UNIQUE (name)
);

CREATE TABLE IF NOT EXISTS permissions (
    permission_id uuid NOT NULL,
    name text NOT NULL,
    resource_type text NOT NULL,
    action text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT permissions_pkey PRIMARY KEY (permission_id),
    CONSTRAINT permissions_name_key UNIQUE (name),
    CONSTRAINT permissions_resource_action_key UNIQUE (resource_type, action)
);

CREATE TABLE IF NOT EXISTS role_permissions (
    role_id uuid NOT NULL,
    permission_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT role_permissions_pkey PRIMARY KEY (role_id, permission_id),
    CONSTRAINT role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES roles (role_id),
    CONSTRAINT role_permissions_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES permissions (permission_id)
);

CREATE TABLE IF NOT EXISTS role_bindings (
    binding_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role_id uuid NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid,
    space_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    CONSTRAINT role_bindings_pkey PRIMARY KEY (binding_id),
    CONSTRAINT role_bindings_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT role_bindings_role_id_fkey FOREIGN KEY (role_id) REFERENCES roles (role_id)
);

CREATE INDEX IF NOT EXISTS idx_role_bindings_user_scope_active
    ON role_bindings (user_id, resource_type, resource_id, space_id)
    WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS resource_acl (
    acl_id uuid NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid NOT NULL,
    user_id uuid,
    role_id uuid,
    permission_id uuid NOT NULL,
    owner_user_id uuid,
    space_id uuid,
    visibility text NOT NULL DEFAULT 'public',
    moderation_state text NOT NULL DEFAULT 'visible',
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    CONSTRAINT resource_acl_pkey PRIMARY KEY (acl_id),
    CONSTRAINT resource_acl_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT resource_acl_role_id_fkey FOREIGN KEY (role_id) REFERENCES roles (role_id),
    CONSTRAINT resource_acl_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES permissions (permission_id),
    CONSTRAINT resource_acl_owner_user_id_fkey FOREIGN KEY (owner_user_id) REFERENCES users (id),
    CONSTRAINT resource_acl_visibility_check CHECK (visibility IN ('public', 'members', 'private')),
    CONSTRAINT resource_acl_moderation_state_check CHECK (moderation_state IN ('visible', 'hidden', 'locked', 'deleted'))
);

CREATE INDEX IF NOT EXISTS idx_resource_acl_query_scope
    ON resource_acl (resource_type, resource_id, space_id, visibility, moderation_state)
    WHERE revoked_at IS NULL;

COMMIT;
