package GPForum::Schema::Result::ReputationEvent;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('reputation_events');

__PACKAGE__->add_columns(
    reputation_event_id => { data_type => 'uuid',    is_nullable => 0 },
    user_id             => { data_type => 'uuid',    is_nullable => 0 },
    actor_id            => { data_type => 'uuid',    is_nullable => 1 },
    source_type         => { data_type => 'text',    is_nullable => 0 },
    source_id           => { data_type => 'uuid',    is_nullable => 1 },
    delta               => { data_type => 'integer', is_nullable => 0 },
    reason              => { data_type => 'text',    is_nullable => 0 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key('reputation_event_id');
__PACKAGE__->belongs_to( user => 'GPForum::Schema::Result::User', 'user_id' );
__PACKAGE__->belongs_to(
    actor => 'GPForum::Schema::Result::User',
    'actor_id',
    { join_type => 'left' }
);

1;
