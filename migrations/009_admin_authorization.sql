-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

ALTER TABLE role_bindings
    ADD COLUMN IF NOT EXISTS created_by_user_id uuid;

CREATE INDEX IF NOT EXISTS idx_role_bindings_created_by
    ON role_bindings (created_by_user_id, created_at DESC)
    WHERE created_by_user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS admin_role_audit_projection (
    projection_id uuid NOT NULL,
    binding_id uuid NOT NULL,
    actor_user_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role_id uuid NOT NULL,
    action text NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid,
    space_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT admin_role_audit_projection_pkey PRIMARY KEY (projection_id),
    CONSTRAINT admin_role_audit_projection_action_check CHECK (action IN ('created', 'revoked'))
);

CREATE INDEX IF NOT EXISTS idx_admin_role_audit_projection_actor
    ON admin_role_audit_projection (actor_user_id, created_at DESC);

COMMIT;
