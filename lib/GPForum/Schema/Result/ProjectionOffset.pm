package GPForum::Schema::Result::ProjectionOffset;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('projection_offsets');

__PACKAGE__->add_columns(
    projection_name => {
        data_type   => 'text',
        is_nullable => 0,
    },
    last_event_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    last_event_created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    lag_seconds => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
    },
    status => {
        data_type     => 'text',
        default_value => 'initializing',
        is_nullable   => 0,
    },
    updated_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('projection_name');

1;
