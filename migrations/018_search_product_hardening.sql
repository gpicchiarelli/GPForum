BEGIN;

ALTER TABLE search_documents
    ADD COLUMN IF NOT EXISTS category_id uuid,
    ADD COLUMN IF NOT EXISTS author_user_id uuid,
    ADD COLUMN IF NOT EXISTS source_created_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_search_documents_public_filter_rank
    ON search_documents
        (category_id, author_user_id, source_created_at DESC, entity_id)
    WHERE visibility = 'public'
      AND permission_scope = 'public';

CREATE INDEX IF NOT EXISTS idx_search_documents_source_created
    ON search_documents (source_created_at DESC, entity_id)
    WHERE visibility IN ('public', 'members')
      AND permission_scope IN ('public', 'members');

COMMIT;
