package GPForum::Schema::Result::LegacyIdMap;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('legacy_id_map');

__PACKAGE__->add_columns(
    legacy_id_map_id => { data_type => 'uuid', is_nullable => 0 },
    import_job_id    => { data_type => 'uuid', is_nullable => 0 },
    legacy_type      => { data_type => 'text', is_nullable => 0 },
    legacy_id        => { data_type => 'text', is_nullable => 0 },
    native_type      => { data_type => 'text', is_nullable => 0 },
    native_id        => { data_type => 'uuid', is_nullable => 0 },
    canonical_url    => { data_type => 'text', is_nullable => 1 },
    visibility       => { data_type => 'text', is_nullable => 0 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key('legacy_id_map_id');
__PACKAGE__->add_unique_constraint(
    legacy_id_map_source_key => [ 'legacy_type', 'legacy_id' ] );
__PACKAGE__->belongs_to(
    import_job => 'GPForum::Schema::Result::ImportJob',
    'import_job_id'
);

1;
