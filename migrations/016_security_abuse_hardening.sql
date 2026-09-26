-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE TABLE IF NOT EXISTS rate_limit_buckets (
    scope text NOT NULL,
    actor_hash text NOT NULL,
    action text NOT NULL,
    window_started_at timestamptz NOT NULL,
    window_seconds integer NOT NULL,
    observed_count integer NOT NULL DEFAULT 0,
    blocked_count integer NOT NULL DEFAULT 0,
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    CONSTRAINT rate_limit_buckets_pkey
        PRIMARY KEY (scope, actor_hash, action, window_started_at),
    CONSTRAINT rate_limit_buckets_window_seconds_check
        CHECK (window_seconds > 0),
    CONSTRAINT rate_limit_buckets_observed_count_check
        CHECK (observed_count >= 0),
    CONSTRAINT rate_limit_buckets_blocked_count_check
        CHECK (blocked_count >= 0),
    CONSTRAINT rate_limit_buckets_expires_after_window_check
        CHECK (expires_at > window_started_at)
) WITH (fillfactor = 90);

CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_expiry
    ON rate_limit_buckets (expires_at);

CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_scope_action_window
    ON rate_limit_buckets (scope, action, window_started_at DESC);

CREATE INDEX IF NOT EXISTS idx_reports_reporter_target_open
    ON reports (reporter_user_id, target_type, target_id, created_at DESC)
    WHERE status IN ('open', 'triaged');

COMMIT;
