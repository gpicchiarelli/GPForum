# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::Attachment;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('attachments');

__PACKAGE__->add_columns(
    attachment_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    owner_user_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    object_key => {
        data_type   => 'text',
        is_nullable => 0,
    },
    original_filename => {
        data_type   => 'text',
        is_nullable => 0,
    },
    media_type => {
        data_type   => 'text',
        is_nullable => 0,
    },
    byte_size => {
        data_type   => 'bigint',
        is_nullable => 0,
    },
    checksum => {
        data_type   => 'text',
        is_nullable => 0,
    },
    state => {
        data_type     => 'text',
        default_value => 'intent',
        is_nullable   => 0,
    },

    # The upload's verdict: 'pending' until decided, then 'clean', 'infected'
    # (an antivirus found something; scan_signature names it) or 'failed' (the
    # worker found the stored bytes no longer sniff to the declared media
    # type). Verdicts only tighten: nothing becomes clean over infected or
    # failed. scan_engine records what decided -- the system antivirus and its
    # signature database, or 'format-check' when scanning was off; NULL for a
    # file decided before ADR 0108, which the backfill job then scans. Only
    # 'clean' is ever served.
    scan_status => {
        data_type     => 'text',
        default_value => 'pending',
        is_nullable   => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    uploaded_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    scanned_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    quarantined_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    scan_engine => {
        data_type   => 'text',
        is_nullable => 1,
    },
    scan_signature => {
        data_type   => 'text',
        is_nullable => 1,
    },

    # Failed attempts by the scheduled rescan or backfill, and the last error.
    scan_attempts => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
    },
    scan_error => {
        data_type   => 'text',
        is_nullable => 1,
    },
    deleted_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('attachment_id');
__PACKAGE__->add_unique_constraint(
    attachments_object_key_key => ['object_key'] );
__PACKAGE__->belongs_to(
    owner => 'GPForum::Schema::Result::User',
    'owner_user_id'
);
__PACKAGE__->has_many(
    links => 'GPForum::Schema::Result::AttachmentLink',
    'attachment_id'
);
__PACKAGE__->has_many(
    variants => 'GPForum::Schema::Result::AttachmentVariant',
    'attachment_id'
);

1;

