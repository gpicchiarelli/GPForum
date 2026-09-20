package GPForum::Schema::Result::EventIdempotencyKey;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('event_idempotency_keys');

__PACKAGE__->add_columns(
    idempotency_key => {
        data_type   => 'text',
        is_nullable => 0,
    },
    event_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('idempotency_key');

1;
