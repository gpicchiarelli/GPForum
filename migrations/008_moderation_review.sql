-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE TABLE IF NOT EXISTS reports (
    report_id uuid NOT NULL,
    reporter_user_id uuid NOT NULL,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    reason text NOT NULL,
    details text NOT NULL DEFAULT '',
    status text NOT NULL DEFAULT 'open',
    assigned_moderator_user_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,
    resolution text,
    CONSTRAINT reports_pkey PRIMARY KEY (report_id),
    CONSTRAINT reports_reporter_user_id_fkey FOREIGN KEY (reporter_user_id) REFERENCES users (id),
    CONSTRAINT reports_assigned_moderator_user_id_fkey FOREIGN KEY (assigned_moderator_user_id) REFERENCES users (id),
    CONSTRAINT reports_target_type_check CHECK (target_type IN ('thread', 'post', 'user')),
    CONSTRAINT reports_status_check CHECK (status IN ('open', 'triaged', 'resolved', 'rejected')),
    CONSTRAINT reports_resolved_after_created_check CHECK (resolved_at IS NULL OR resolved_at >= created_at)
);

CREATE INDEX IF NOT EXISTS idx_reports_queue
    ON reports (status, created_at, report_id);

CREATE TABLE IF NOT EXISTS moderation_actions (
    moderation_action_id uuid NOT NULL,
    actor_user_id uuid NOT NULL,
    action_type text NOT NULL,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    reason text NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    reversed_at timestamptz,
    reversed_by_user_id uuid,
    CONSTRAINT moderation_actions_pkey PRIMARY KEY (moderation_action_id),
    CONSTRAINT moderation_actions_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES users (id),
    CONSTRAINT moderation_actions_reversed_by_user_id_fkey FOREIGN KEY (reversed_by_user_id) REFERENCES users (id),
    CONSTRAINT moderation_actions_target_type_check CHECK (target_type IN ('thread', 'post', 'user')),
    CONSTRAINT moderation_actions_reversed_after_created_check CHECK (reversed_at IS NULL OR reversed_at >= created_at)
);

CREATE INDEX IF NOT EXISTS idx_moderation_actions_target
    ON moderation_actions (target_type, target_id, created_at DESC);

CREATE TABLE IF NOT EXISTS suspensions (
    suspension_id uuid NOT NULL,
    user_id uuid NOT NULL,
    actor_user_id uuid NOT NULL,
    reason text NOT NULL,
    valid_from timestamptz NOT NULL DEFAULT now(),
    valid_to timestamptz,
    revoked_at timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT suspensions_pkey PRIMARY KEY (suspension_id),
    CONSTRAINT suspensions_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT suspensions_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES users (id),
    CONSTRAINT suspensions_valid_range_check CHECK (valid_to IS NULL OR valid_to >= valid_from),
    CONSTRAINT suspensions_revoked_after_valid_from_check CHECK (revoked_at IS NULL OR revoked_at >= valid_from)
);

CREATE INDEX IF NOT EXISTS idx_suspensions_active
    ON suspensions (user_id, valid_from, valid_to)
    WHERE revoked_at IS NULL;

COMMIT;
