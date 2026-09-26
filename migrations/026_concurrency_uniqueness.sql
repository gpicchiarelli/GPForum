-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_reports_reporter_target_open_unique
    ON reports (reporter_user_id, target_type, target_id)
    WHERE status IN ('open', 'triaged');

ALTER TABLE moderation_actions
    ADD COLUMN IF NOT EXISTS command_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS idx_moderation_actions_command_id
    ON moderation_actions (command_id)
    WHERE command_id IS NOT NULL;

COMMIT;
