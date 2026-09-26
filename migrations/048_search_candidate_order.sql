-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

-- Search ranks only the newest matches (quality program 8.10). Ranking scores
-- every candidate before the first page is known, so a word most documents
-- hold was ranked over the whole corpus, linear in its size. Searcher now
-- takes the newest search_candidate_limit matches first, ordered by
-- source_created_at DESC, entity_id DESC, and ranks only those. This index
-- serves that order: for a common word the planner walks it from the newest
-- document and stops at the limit, while a rare word keeps the BitmapOr over
-- the GIN and trigram indexes. It is not partial, because visibility is judged
-- in the query, against the live category and space (ADR 0102).
--
-- The planner chooses that walk only if it can tell how many matches survive
-- the join to categories and spaces, which needs statistics on both. They are
-- small and written only by an administrator, so autovacuum's default of 50
-- changed rows before an ANALYZE can leave them never analysed for the life of
-- a forum. On the planner's guesses for a never-analysed table it read and
-- sorted every match instead: 32 ms rather than 4 ms at 30,000 documents on
-- PostgreSQL 18, the cost the cap exists to remove. A threshold of zero lets
-- the scale factor alone decide, so creating or editing a category or space
-- gets them analysed; the ANALYZE covers the forum being upgraded now.
--
-- The four partial indexes dropped here could never be used. Each is partial
-- on permission_scope, and no statement in lib/ states that column: the
-- planner only uses a partial index when the query implies its predicate.
-- Verified on PostgreSQL 18 against the statements Searcher sends -- search
-- and autocomplete, anonymous and member, with every filter -- by EXPLAIN,
-- also with sequential scans disabled and every other search_documents index
-- removed: no plan used any of the four, and after running every statement
-- pg_stat_user_indexes showed idx_scan = 0 for each. They were write cost on
-- every document the indexer writes.
--
-- Not CONCURRENTLY: the runner executes migrations inside a transaction. The
-- build takes a SHARE lock on search_documents, which blocks the indexer's
-- writes but not searches, and each DROP INDEX takes a brief ACCESS EXCLUSIVE
-- lock, which blocks both. On a large forum run this during a maintenance
-- window.

BEGIN;

CREATE INDEX IF NOT EXISTS idx_search_documents_created
    ON search_documents (source_created_at DESC, entity_id DESC);

DROP INDEX IF EXISTS idx_search_documents_public_latest;

DROP INDEX IF EXISTS idx_search_documents_public_title_prefix;

DROP INDEX IF EXISTS idx_search_documents_public_filter_rank;

DROP INDEX IF EXISTS idx_search_documents_source_created;

ALTER TABLE categories SET (autovacuum_analyze_threshold = 0);

ALTER TABLE spaces SET (autovacuum_analyze_threshold = 0);

ANALYZE categories;

ANALYZE spaces;

COMMIT;
