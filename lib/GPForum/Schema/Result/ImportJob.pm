# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::ImportJob;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

use GPForum::Schema::JsonColumn;

our $VERSION = '0.001';

__PACKAGE__->table('import_jobs');

__PACKAGE__->add_columns(
    import_job_id => { data_type => 'uuid', is_nullable => 0 },
    source_system => { data_type => 'text', is_nullable => 0 },
    adapter_name  => { data_type => 'text', is_nullable => 0 },
    status        => { data_type => 'text', is_nullable => 0 },
    dry_run => { data_type => 'boolean', is_nullable => 0, default_value => 1 },
    manifest =>
      { data_type => 'jsonb', is_nullable => 0, default_value => '{}' },
    progress =>
      { data_type => 'jsonb', is_nullable => 0, default_value => '{}' },
    created_by => { data_type => 'uuid',                     is_nullable => 1 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
    started_at => { data_type => 'timestamp with time zone', is_nullable => 1 },
    finished_at =>
      { data_type => 'timestamp with time zone', is_nullable => 1 },
);

GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__);

__PACKAGE__->set_primary_key('import_job_id');
__PACKAGE__->has_many(
    failures => 'GPForum::Schema::Result::ImportFailure',
    'import_job_id'
);

1;
