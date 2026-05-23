BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS spaces (
    space_id uuid NOT NULL,
    slug text NOT NULL,
    title text NOT NULL,
    description text NOT NULL DEFAULT '',
    visibility text NOT NULL DEFAULT 'public',
    position integer NOT NULL DEFAULT 0,
    version bigint NOT NULL DEFAULT 1,
    permission_version bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CONSTRAINT spaces_pkey PRIMARY KEY (space_id),
    CONSTRAINT spaces_slug_key UNIQUE (slug),
    CONSTRAINT spaces_visibility_check CHECK (visibility IN ('public', 'members', 'private')),
    CONSTRAINT spaces_version_check CHECK (version > 0),
    CONSTRAINT spaces_permission_version_check CHECK (permission_version > 0)
);

CREATE TABLE IF NOT EXISTS categories (
    category_id uuid NOT NULL,
    space_id uuid NOT NULL,
    slug text NOT NULL,
    title text NOT NULL,
    description text NOT NULL DEFAULT '',
    visibility text NOT NULL DEFAULT 'public',
    position integer NOT NULL DEFAULT 0,
    version bigint NOT NULL DEFAULT 1,
    permission_version bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CONSTRAINT categories_pkey PRIMARY KEY (category_id),
    CONSTRAINT categories_space_id_fkey FOREIGN KEY (space_id) REFERENCES spaces (space_id),
    CONSTRAINT categories_space_slug_key UNIQUE (space_id, slug),
    CONSTRAINT categories_visibility_check CHECK (visibility IN ('public', 'members', 'private')),
    CONSTRAINT categories_version_check CHECK (version > 0),
    CONSTRAINT categories_permission_version_check CHECK (permission_version > 0)
);

CREATE INDEX IF NOT EXISTS idx_categories_space_position
    ON categories (space_id, position)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS threads (
    thread_id uuid NOT NULL,
    category_id uuid NOT NULL,
    author_user_id uuid NOT NULL,
    title text NOT NULL,
    slug text NOT NULL,
    pinned boolean NOT NULL DEFAULT false,
    visibility text NOT NULL DEFAULT 'public',
    moderation_state text NOT NULL DEFAULT 'visible',
    locked_at timestamptz,
    last_activity_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1,
    visibility_version bigint NOT NULL DEFAULT 1,
    permission_version bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    deleted_by uuid,
    CONSTRAINT threads_pkey PRIMARY KEY (thread_id),
    CONSTRAINT threads_category_id_fkey FOREIGN KEY (category_id) REFERENCES categories (category_id),
    CONSTRAINT threads_author_user_id_fkey FOREIGN KEY (author_user_id) REFERENCES users (id),
    CONSTRAINT threads_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES users (id),
    CONSTRAINT threads_visibility_check CHECK (visibility IN ('public', 'members', 'private')),
    CONSTRAINT threads_moderation_state_check CHECK (moderation_state IN ('visible', 'hidden', 'locked', 'deleted')),
    CONSTRAINT threads_version_check CHECK (version > 0),
    CONSTRAINT threads_visibility_version_check CHECK (visibility_version > 0),
    CONSTRAINT threads_permission_version_check CHECK (permission_version > 0)
) WITH (fillfactor = 90);

CREATE INDEX IF NOT EXISTS idx_threads_category_activity
    ON threads (category_id, pinned DESC, last_activity_at DESC)
    INCLUDE (title, author_user_id)
    WHERE deleted_at IS NULL AND moderation_state = 'visible';

CREATE TABLE IF NOT EXISTS posts (
    post_id uuid NOT NULL,
    thread_id uuid NOT NULL,
    author_user_id uuid NOT NULL,
    current_body_id uuid,
    current_revision_id uuid,
    position bigint NOT NULL,
    visibility text NOT NULL DEFAULT 'public',
    moderation_state text NOT NULL DEFAULT 'visible',
    version bigint NOT NULL DEFAULT 1,
    visibility_version bigint NOT NULL DEFAULT 1,
    permission_version bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    hidden_at timestamptz,
    locked_at timestamptz,
    deleted_at timestamptz,
    deleted_by uuid,
    CONSTRAINT posts_pkey PRIMARY KEY (post_id),
    CONSTRAINT posts_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES threads (thread_id),
    CONSTRAINT posts_author_user_id_fkey FOREIGN KEY (author_user_id) REFERENCES users (id),
    CONSTRAINT posts_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES users (id),
    CONSTRAINT posts_thread_position_key UNIQUE (thread_id, position),
    CONSTRAINT posts_visibility_check CHECK (visibility IN ('public', 'members', 'private')),
    CONSTRAINT posts_moderation_state_check CHECK (moderation_state IN ('visible', 'hidden', 'locked', 'deleted')),
    CONSTRAINT posts_version_check CHECK (version > 0),
    CONSTRAINT posts_visibility_version_check CHECK (visibility_version > 0),
    CONSTRAINT posts_permission_version_check CHECK (permission_version > 0)
);

CREATE TABLE IF NOT EXISTS posts_archive (
    LIKE posts INCLUDING DEFAULTS INCLUDING CONSTRAINTS
);

CREATE TABLE IF NOT EXISTS post_bodies (
    body_id uuid NOT NULL,
    post_id uuid NOT NULL,
    body_format text NOT NULL DEFAULT 'markdown',
    body_source text NOT NULL,
    body_rendered_safe text NOT NULL,
    source_hash text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT post_bodies_pkey PRIMARY KEY (body_id),
    CONSTRAINT post_bodies_post_id_fkey FOREIGN KEY (post_id) REFERENCES posts (post_id),
    CONSTRAINT post_bodies_body_format_check CHECK (body_format IN ('markdown', 'plain'))
);

CREATE TABLE IF NOT EXISTS post_revisions (
    revision_id uuid NOT NULL,
    post_id uuid NOT NULL,
    body_id uuid NOT NULL,
    editor_user_id uuid NOT NULL,
    revision_number integer NOT NULL,
    edit_reason text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT post_revisions_pkey PRIMARY KEY (revision_id),
    CONSTRAINT post_revisions_post_id_fkey FOREIGN KEY (post_id) REFERENCES posts (post_id),
    CONSTRAINT post_revisions_body_id_fkey FOREIGN KEY (body_id) REFERENCES post_bodies (body_id),
    CONSTRAINT post_revisions_editor_user_id_fkey FOREIGN KEY (editor_user_id) REFERENCES users (id),
    CONSTRAINT post_revisions_post_revision_number_key UNIQUE (post_id, revision_number),
    CONSTRAINT post_revisions_revision_number_check CHECK (revision_number > 0)
);

ALTER TABLE posts
    ADD CONSTRAINT posts_current_body_id_fkey
    FOREIGN KEY (current_body_id) REFERENCES post_bodies (body_id)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE posts
    ADD CONSTRAINT posts_current_revision_id_fkey
    FOREIGN KEY (current_revision_id) REFERENCES post_revisions (revision_id)
    DEFERRABLE INITIALLY DEFERRED;

CREATE INDEX IF NOT EXISTS idx_posts_visible_thread
    ON posts (thread_id, position)
    WHERE deleted_at IS NULL AND moderation_state = 'visible';

CREATE TABLE IF NOT EXISTS thread_counters (
    thread_id uuid NOT NULL,
    reply_count bigint NOT NULL DEFAULT 0,
    visible_reply_count bigint NOT NULL DEFAULT 0,
    last_post_id uuid,
    last_activity_at timestamptz NOT NULL DEFAULT now(),
    version bigint NOT NULL DEFAULT 1,
    reconciled_at timestamptz,
    CONSTRAINT thread_counters_pkey PRIMARY KEY (thread_id),
    CONSTRAINT thread_counters_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES threads (thread_id),
    CONSTRAINT thread_counters_last_post_id_fkey FOREIGN KEY (last_post_id) REFERENCES posts (post_id),
    CONSTRAINT thread_counters_reply_count_check CHECK (reply_count >= 0),
    CONSTRAINT thread_counters_visible_reply_count_check CHECK (visible_reply_count >= 0),
    CONSTRAINT thread_counters_version_check CHECK (version > 0)
) WITH (fillfactor = 80);

CREATE TABLE IF NOT EXISTS category_stats (
    category_id uuid NOT NULL,
    thread_count bigint NOT NULL DEFAULT 0,
    visible_thread_count bigint NOT NULL DEFAULT 0,
    post_count bigint NOT NULL DEFAULT 0,
    version bigint NOT NULL DEFAULT 1,
    reconciled_at timestamptz,
    CONSTRAINT category_stats_pkey PRIMARY KEY (category_id),
    CONSTRAINT category_stats_category_id_fkey FOREIGN KEY (category_id) REFERENCES categories (category_id),
    CONSTRAINT category_stats_thread_count_check CHECK (thread_count >= 0),
    CONSTRAINT category_stats_visible_thread_count_check CHECK (visible_thread_count >= 0),
    CONSTRAINT category_stats_post_count_check CHECK (post_count >= 0),
    CONSTRAINT category_stats_version_check CHECK (version > 0)
) WITH (fillfactor = 80);

CREATE TABLE IF NOT EXISTS search_documents (
    search_document_id uuid NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid NOT NULL,
    space_id uuid,
    visibility text NOT NULL,
    permission_scope text NOT NULL,
    visibility_version bigint NOT NULL,
    permission_version bigint NOT NULL,
    language text NOT NULL DEFAULT 'simple',
    title text NOT NULL,
    title_normalized text GENERATED ALWAYS AS (lower(title)) STORED,
    body text NOT NULL,
    search_vector tsvector NOT NULL,
    source_version bigint NOT NULL,
    indexed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT search_documents_pkey PRIMARY KEY (search_document_id),
    CONSTRAINT search_documents_entity_key UNIQUE (entity_type, entity_id),
    CONSTRAINT search_documents_visibility_check CHECK (visibility IN ('public', 'members', 'private')),
    CONSTRAINT search_documents_visibility_version_check CHECK (visibility_version > 0),
    CONSTRAINT search_documents_permission_version_check CHECK (permission_version > 0),
    CONSTRAINT search_documents_source_version_check CHECK (source_version > 0)
);

CREATE INDEX IF NOT EXISTS idx_search_documents_vector
    ON search_documents USING GIN (search_vector);

CREATE INDEX IF NOT EXISTS idx_search_documents_title_trgm
    ON search_documents USING GIN (title_normalized gin_trgm_ops);

CREATE TABLE IF NOT EXISTS notifications (
    notification_id uuid NOT NULL,
    recipient_user_id uuid NOT NULL,
    source_type text NOT NULL,
    source_id uuid,
    notification_type text NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT notifications_pkey PRIMARY KEY (notification_id, created_at),
    CONSTRAINT notifications_recipient_user_id_fkey FOREIGN KEY (recipient_user_id) REFERENCES users (id)
) PARTITION BY RANGE (created_at);

CREATE TABLE IF NOT EXISTS notifications_default
    PARTITION OF notifications DEFAULT;

CREATE INDEX IF NOT EXISTS idx_notifications_recipient_created_at
    ON notifications (recipient_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notifications_created_at_brin
    ON notifications USING BRIN (created_at);

CREATE TABLE IF NOT EXISTS notification_reads (
    notification_id uuid NOT NULL,
    recipient_user_id uuid NOT NULL,
    read_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT notification_reads_pkey PRIMARY KEY (notification_id, recipient_user_id),
    CONSTRAINT notification_reads_recipient_user_id_fkey FOREIGN KEY (recipient_user_id) REFERENCES users (id)
);

CREATE TABLE IF NOT EXISTS notification_inbox (
    recipient_user_id uuid NOT NULL,
    notification_id uuid NOT NULL,
    created_at timestamptz NOT NULL,
    read_at timestamptz,
    rank_score numeric NOT NULL DEFAULT 0,
    CONSTRAINT notification_inbox_pkey PRIMARY KEY (recipient_user_id, notification_id),
    CONSTRAINT notification_inbox_recipient_user_id_fkey FOREIGN KEY (recipient_user_id) REFERENCES users (id)
);

CREATE TABLE IF NOT EXISTS user_feed_items (
    user_id uuid NOT NULL,
    item_type text NOT NULL,
    item_id uuid NOT NULL,
    created_at timestamptz NOT NULL,
    rank_score numeric NOT NULL DEFAULT 0,
    visibility_version bigint NOT NULL,
    permission_version bigint NOT NULL,
    CONSTRAINT user_feed_items_pkey PRIMARY KEY (user_id, item_type, item_id),
    CONSTRAINT user_feed_items_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT user_feed_items_visibility_version_check CHECK (visibility_version > 0),
    CONSTRAINT user_feed_items_permission_version_check CHECK (permission_version > 0)
);

COMMIT;
