-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_credentials_active_password_unique
    ON credentials (user_id)
    WHERE revoked_at IS NULL AND type = 'password';

COMMIT;
