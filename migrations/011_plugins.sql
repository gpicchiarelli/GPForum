-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE TABLE IF NOT EXISTS plugins (
    plugin_id uuid NOT NULL,
    name text NOT NULL,
    version text NOT NULL,
    author text NOT NULL,
    compatible_gpforum_range text NOT NULL,
    status text NOT NULL DEFAULT 'installed',
    capabilities jsonb NOT NULL DEFAULT '[]'::jsonb,
    required_permissions jsonb NOT NULL DEFAULT '[]'::jsonb,
    config_schema jsonb NOT NULL DEFAULT '{}'::jsonb,
    installed_at timestamptz NOT NULL DEFAULT now(),
    enabled_at timestamptz,
    disabled_at timestamptz,
    CONSTRAINT plugins_pkey PRIMARY KEY (plugin_id),
    CONSTRAINT plugins_name_version_key UNIQUE (name, version),
    CONSTRAINT plugins_status_check CHECK (status IN ('installed', 'enabled', 'disabled', 'upgrade_required', 'failed')),
    CONSTRAINT plugins_disabled_after_installed_check CHECK (disabled_at IS NULL OR disabled_at >= installed_at)
);

CREATE INDEX IF NOT EXISTS idx_plugins_status_name
    ON plugins (status, name);

CREATE TABLE IF NOT EXISTS plugin_hooks (
    hook_id uuid NOT NULL,
    plugin_id uuid NOT NULL,
    hook_name text NOT NULL,
    callback_name text NOT NULL,
    execution_order integer NOT NULL DEFAULT 100,
    timeout_ms integer NOT NULL DEFAULT 500,
    side_effect_policy text NOT NULL DEFAULT 'read_only',
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT plugin_hooks_pkey PRIMARY KEY (hook_id),
    CONSTRAINT plugin_hooks_plugin_id_fkey FOREIGN KEY (plugin_id) REFERENCES plugins (plugin_id),
    CONSTRAINT plugin_hooks_side_effect_policy_check CHECK (side_effect_policy IN ('read_only', 'writes_plugin_data', 'writes_core_data', 'external_io')),
    CONSTRAINT plugin_hooks_timeout_positive_check CHECK (timeout_ms > 0)
);

CREATE INDEX IF NOT EXISTS idx_plugin_hooks_dispatch
    ON plugin_hooks (hook_name, enabled, execution_order);

CREATE TABLE IF NOT EXISTS plugin_failures (
    plugin_failure_id uuid NOT NULL,
    plugin_id uuid NOT NULL,
    hook_name text,
    error_class text NOT NULL,
    error_message text NOT NULL,
    context jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT plugin_failures_pkey PRIMARY KEY (plugin_failure_id),
    CONSTRAINT plugin_failures_plugin_id_fkey FOREIGN KEY (plugin_id) REFERENCES plugins (plugin_id)
);

CREATE INDEX IF NOT EXISTS idx_plugin_failures_plugin_created
    ON plugin_failures (plugin_id, created_at DESC);

COMMIT;
