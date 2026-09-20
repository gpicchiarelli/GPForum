BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_role_bindings_active_unique
    ON role_bindings (user_id, role_id, resource_type, resource_id, space_id)
    NULLS NOT DISTINCT
    WHERE revoked_at IS NULL;

COMMIT;
