package GPForum::Schema::Result::OutboxMessage;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('outbox_messages');

__PACKAGE__->add_columns(
    outbox_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    event_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    queue => {
        data_type   => 'text',
        is_nullable => 0,
    },
    job_type => {
        data_type   => 'text',
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
    available_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    locked_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    attempts => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
    },
    status => {
        data_type     => 'text',
        default_value => 'pending',
        is_nullable   => 0,
    },
    last_error => {
        data_type   => 'text',
        is_nullable => 1,
    },
    next_attempt_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    locked_by => {
        data_type   => 'text',
        is_nullable => 1,
    },
    locked_until => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    attempt_count => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
    },
    last_error_class => {
        data_type   => 'text',
        is_nullable => 1,
    },
    failure_type => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('outbox_id');
__PACKAGE__->add_unique_constraint(
    outbox_messages_idempotency_key_key => ['idempotency_key'] );

1;
