package GPForum::Schema::Result::CommandLog;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

use GPForum::Schema::JsonColumn;

our $VERSION = '0.001';

__PACKAGE__->table('command_log');

__PACKAGE__->add_columns(
    command_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    command_type => {
        data_type   => 'text',
        is_nullable => 0,
    },
    actor_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    correlation_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    idempotency_key => {
        data_type   => 'text',
        is_nullable => 0,
    },
    payload => {
        data_type     => 'jsonb',
        default_value => '{}',
        is_nullable   => 0,
    },
    response_hash => {
        data_type   => 'text',
        is_nullable => 1,
    },
    status => {
        data_type     => 'text',
        default_value => 'accepted',
        is_nullable   => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    handled_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
);

GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__);

__PACKAGE__->set_primary_key('command_id');
__PACKAGE__->add_unique_constraint(
    command_log_idempotency_key_key => ['idempotency_key'] );

1;
