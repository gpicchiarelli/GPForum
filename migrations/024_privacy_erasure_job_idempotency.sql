-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_erasure_jobs_request_unique
    ON erasure_jobs (deletion_request_id);

COMMIT;
