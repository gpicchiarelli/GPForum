-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

-- The automatic theme: the light palette until the reader's device asks for
-- dark, and the dark one then. It becomes a value a member may keep and the
-- one a new member starts with. A member who has 'default' keeps it, and it
-- stays the light theme: the row does not say whether they chose it or only
-- never changed it, so it is not changed for them.

BEGIN;

ALTER TABLE users
    DROP CONSTRAINT users_preferred_theme_check,
    ADD CONSTRAINT users_preferred_theme_check
        CHECK (preferred_theme IN ('auto', 'default', 'dark', 'high_contrast')),
    ALTER COLUMN preferred_theme SET DEFAULT 'auto';

COMMIT;
