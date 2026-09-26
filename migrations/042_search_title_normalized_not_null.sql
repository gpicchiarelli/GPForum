-- GPForum search title_normalized NOT NULL.
--
-- title_normalized is GENERATED ALWAYS AS (lower(title)) STORED over a NOT
-- NULL title, so it can never be null, but the column never said so: the
-- database reported it nullable while GPForum::Schema::Result::SearchDocument
-- declared it NOT NULL. t/integration/postgres-schema-drift.t compares every
-- Result class with the schema the migrations build, and this was the one
-- column on which they disagreed. The constraint states what the expression
-- already guarantees, and lets the planner rely on it.
--
-- SET NOT NULL scans search_documents under an ACCESS EXCLUSIVE lock, which
-- blocks searches and indexing for its duration. On a large forum run this
-- during a maintenance window.

BEGIN;

ALTER TABLE search_documents ALTER COLUMN title_normalized SET NOT NULL;

COMMIT;
