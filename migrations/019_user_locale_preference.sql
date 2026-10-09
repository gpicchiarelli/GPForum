-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS preferred_locale text NOT NULL DEFAULT 'en',
    ADD CONSTRAINT users_preferred_locale_check CHECK (preferred_locale IN ('en', 'it'));

COMMIT;
