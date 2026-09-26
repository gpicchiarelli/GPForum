-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

BEGIN;

CREATE TABLE IF NOT EXISTS attachments (
    attachment_id uuid NOT NULL,
    owner_user_id uuid NOT NULL,
    object_key text NOT NULL,
    original_filename text NOT NULL,
    media_type text NOT NULL,
    byte_size bigint NOT NULL,
    checksum text NOT NULL,
    state text NOT NULL DEFAULT 'intent',
    scan_status text NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT now(),
    uploaded_at timestamptz,
    scanned_at timestamptz,
    quarantined_at timestamptz,
    deleted_at timestamptz,
    CONSTRAINT attachments_pkey PRIMARY KEY (attachment_id),
    CONSTRAINT attachments_owner_user_id_fkey FOREIGN KEY (owner_user_id) REFERENCES users (id),
    CONSTRAINT attachments_object_key_key UNIQUE (object_key),
    CONSTRAINT attachments_state_check CHECK (state IN ('intent', 'uploaded', 'available', 'quarantined', 'deleted')),
    CONSTRAINT attachments_scan_status_check CHECK (scan_status IN ('pending', 'clean', 'infected', 'failed')),
    CONSTRAINT attachments_byte_size_check CHECK (byte_size > 0)
);

CREATE INDEX IF NOT EXISTS idx_attachments_owner_state
    ON attachments (owner_user_id, state, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS attachment_links (
    attachment_link_id uuid NOT NULL,
    attachment_id uuid NOT NULL,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT attachment_links_pkey PRIMARY KEY (attachment_link_id),
    CONSTRAINT attachment_links_attachment_id_fkey FOREIGN KEY (attachment_id) REFERENCES attachments (attachment_id),
    CONSTRAINT attachment_links_target_type_check CHECK (target_type IN ('post', 'thread', 'profile')),
    CONSTRAINT attachment_links_target_key UNIQUE (attachment_id, target_type, target_id)
);

CREATE INDEX IF NOT EXISTS idx_attachment_links_target
    ON attachment_links (target_type, target_id, attachment_id);

CREATE TABLE IF NOT EXISTS attachment_variants (
    attachment_variant_id uuid NOT NULL,
    attachment_id uuid NOT NULL,
    variant_type text NOT NULL,
    object_key text NOT NULL,
    media_type text NOT NULL,
    byte_size bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT attachment_variants_pkey PRIMARY KEY (attachment_variant_id),
    CONSTRAINT attachment_variants_attachment_id_fkey FOREIGN KEY (attachment_id) REFERENCES attachments (attachment_id),
    CONSTRAINT attachment_variants_object_key_key UNIQUE (object_key),
    CONSTRAINT attachment_variants_variant_key UNIQUE (attachment_id, variant_type),
    CONSTRAINT attachment_variants_byte_size_check CHECK (byte_size > 0)
);

COMMIT;

