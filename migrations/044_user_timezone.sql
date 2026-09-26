-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

-- 9.3: a member's own time zone, an IANA name such as Europe/Rome. NULL means
-- the forum's default (GPFORUM_DEFAULT_TIMEZONE), so members who never chose
-- follow it if it changes. The application validates the name against the
-- time zone database; a name that later disappears from it falls back to the
-- forum's default when rendering, never to an error.

BEGIN;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS preferred_timezone text,
    ADD CONSTRAINT users_preferred_timezone_length_check
        CHECK (preferred_timezone IS NULL OR length(preferred_timezone) BETWEEN 1 AND 64);

COMMIT;
