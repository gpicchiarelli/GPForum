-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS idx_plugin_hooks_plugin_name_unique
    ON plugin_hooks (plugin_id, hook_name);

COMMIT;
