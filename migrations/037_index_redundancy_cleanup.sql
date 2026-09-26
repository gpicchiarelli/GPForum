-- GPForum index consolidation for the outbox claim and forum read paths.
-- Every drop is verified against the query that justified the index: the
-- claim SQL in lib/GPForum/Service/Outbox/ClaimQuery.pm, the hot-path
-- indexes from migration 014, and the unique index from migration 026.
-- idx_outbox_messages_dispatch trails available_at, which no query in lib/
-- filters, joins or orders on, but its status prefix is the only non-partial
-- one on the table, so idx_outbox_messages_status_created replaces it before
-- the drop and also serves the retention sweep and admin console ordering.
-- The added indexes cover foreign-key columns lib/ reads today and nothing
-- indexes: posts.author_user_id (public profile replies and contribution
-- counts in Identity::ProfileReader, GDPR export in
-- Portability::ExportBundleBuilder), post_bodies.post_id (the same export
-- hydrating bodies), and deletion_requests.requester_user_id (the privacy
-- history list in Privacy::DataRightsReview, which reads closed requests the
-- partial unique index from migration 027 does not cover).

BEGIN;

CREATE INDEX IF NOT EXISTS idx_outbox_messages_status_created
    ON outbox_messages (status, created_at);

DROP INDEX IF EXISTS idx_outbox_messages_dispatch;

DROP INDEX IF EXISTS idx_outbox_messages_ready;

DROP INDEX IF EXISTS idx_outbox_messages_pending_ready;

DROP INDEX IF EXISTS idx_outbox_messages_failed_ready;

DROP INDEX IF EXISTS idx_posts_visible_thread;

DROP INDEX IF EXISTS idx_threads_category_activity;

DROP INDEX IF EXISTS idx_reports_reporter_target_open;

CREATE INDEX IF NOT EXISTS idx_posts_author_created
    ON posts (author_user_id, created_at DESC, post_id DESC);

CREATE INDEX IF NOT EXISTS idx_post_bodies_post
    ON post_bodies (post_id);

CREATE INDEX IF NOT EXISTS idx_deletion_requests_requester_created
    ON deletion_requests (requester_user_id, created_at DESC);

COMMIT;
