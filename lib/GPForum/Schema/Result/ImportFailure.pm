package GPForum::Schema::Result::ImportFailure;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('import_failures');

__PACKAGE__->add_columns(
    import_failure_id  => { data_type => 'uuid', is_nullable => 0 },
    import_job_id      => { data_type => 'uuid', is_nullable => 0 },
    source_record_type => { data_type => 'text', is_nullable => 0 },
    source_record_id   => { data_type => 'text', is_nullable => 0 },
    error_code         => { data_type => 'text', is_nullable => 0 },
    error_message      => { data_type => 'text', is_nullable => 0 },
    payload            =>
      { data_type => 'jsonb', is_nullable => 0, default_value => '{}' },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key('import_failure_id');
__PACKAGE__->belongs_to(
    import_job => 'GPForum::Schema::Result::ImportJob',
    'import_job_id'
);

1;
