-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE TABLE IF NOT EXISTS bookmarks (
    bookmark_id uuid NOT NULL,
    user_id uuid NOT NULL,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    note text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CONSTRAINT bookmarks_pkey PRIMARY KEY (bookmark_id),
    CONSTRAINT bookmarks_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT bookmarks_target_type_check CHECK (target_type IN ('thread', 'post')),
    CONSTRAINT bookmarks_deleted_after_created_check CHECK (deleted_at IS NULL OR deleted_at >= created_at),
    CONSTRAINT bookmarks_user_target_key UNIQUE (user_id, target_type, target_id)
);

CREATE INDEX IF NOT EXISTS idx_bookmarks_user_created
    ON bookmarks (user_id, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS mentions (
    mention_id uuid NOT NULL,
    source_type text NOT NULL,
    source_id uuid NOT NULL,
    actor_id uuid NOT NULL,
    mentioned_user_id uuid NOT NULL,
    mentioned_username text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT mentions_pkey PRIMARY KEY (mention_id),
    CONSTRAINT mentions_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES users (id),
    CONSTRAINT mentions_mentioned_user_id_fkey FOREIGN KEY (mentioned_user_id) REFERENCES users (id),
    CONSTRAINT mentions_source_type_check CHECK (source_type IN ('post', 'thread')),
    CONSTRAINT mentions_source_user_key UNIQUE (source_type, source_id, mentioned_user_id)
);

CREATE INDEX IF NOT EXISTS idx_mentions_mentioned_created
    ON mentions (mentioned_user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS reputation_events (
    reputation_event_id uuid NOT NULL,
    user_id uuid NOT NULL,
    actor_id uuid,
    source_type text NOT NULL,
    source_id uuid,
    delta integer NOT NULL,
    reason text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT reputation_events_pkey PRIMARY KEY (reputation_event_id),
    CONSTRAINT reputation_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT reputation_events_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES users (id),
    CONSTRAINT reputation_events_reason_check CHECK (length(reason) > 0)
);

CREATE INDEX IF NOT EXISTS idx_reputation_events_user_created
    ON reputation_events (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS trust_score_snapshots (
    user_id uuid NOT NULL,
    score integer NOT NULL DEFAULT 0,
    trust_level integer NOT NULL DEFAULT 0,
    calculated_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1,
    CONSTRAINT trust_score_snapshots_pkey PRIMARY KEY (user_id),
    CONSTRAINT trust_score_snapshots_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT trust_score_snapshots_trust_level_check CHECK (trust_level BETWEEN 0 AND 4),
    CONSTRAINT trust_score_snapshots_version_check CHECK (version > 0)
);

CREATE INDEX IF NOT EXISTS idx_user_feed_items_ranked
    ON user_feed_items (user_id, rank_score DESC, created_at DESC);

COMMIT;
