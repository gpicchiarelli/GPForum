package GPForum::Schema::Result::ProjectionGeneration;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('projection_generations');

__PACKAGE__->add_columns(
    generation_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    projection_name => {
        data_type   => 'text',
        is_nullable => 0,
    },
    built_from_event_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    built_from_event_created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    is_active => {
        data_type     => 'boolean',
        default_value => 0,
        is_nullable   => 0,
    },
    status => {
        data_type     => 'text',
        default_value => 'building',
        is_nullable   => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    activated_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('generation_id');

1;
