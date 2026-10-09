-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_import_failures_source_unique
    ON import_failures (import_job_id, source_record_type, source_record_id);

COMMIT;
