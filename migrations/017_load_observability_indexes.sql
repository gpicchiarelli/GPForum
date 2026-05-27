-- GPForum load observability hardening indexes.
-- These indexes are driven by the DB-backed query-plan gate for seeded
-- medium/hot-thread datasets. They keep broad public search and prefix
-- autocomplete bounded without making search authoritative.

CREATE INDEX IF NOT EXISTS idx_search_documents_public_latest
    ON search_documents (indexed_at DESC, entity_id)
    WHERE visibility = 'public'
      AND permission_scope = 'public';

CREATE INDEX IF NOT EXISTS idx_search_documents_public_title_prefix
    ON search_documents (title_normalized text_pattern_ops, entity_id)
    WHERE visibility = 'public'
      AND permission_scope = 'public';
