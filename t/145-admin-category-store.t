package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Admin::CategoryStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

const my $CREATED_SPACES     => 1;
const my $CREATED_CATEGORIES => 1;
const my $CREATED_EVENTS     => 1;
const my $CREATED_OUTBOX     => 1;
const my $CREATED_AUDITS     => 1;
const my $LISTED_CATEGORIES  => 1;

my $fixtures = _fixtures();
my $store    = GPForum::Service::Admin::CategoryStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => $fixtures->{schema},
);

my $created = $store->create_category(
    {
        actor_user_id => 'admin-1',
        description   => 'Welcome board',
        title         => 'General Discussion',
    }
);
is( $created->{title}, 'General Discussion', 'create stores the title' );
is( $created->{slug},  'general-discussion', 'create derives a slug' );
is( $created->{space_id}, 'generated-1',
    'create provisions a default space on a fresh install' );
is( $created->{visibility}, 'public', 'create defaults public visibility' );
is( scalar @{ $fixtures->{spaces}->created },
    $CREATED_SPACES, 'create inserts the default space' );
is( scalar @{ $fixtures->{categories}->created },
    $CREATED_CATEGORIES, 'create inserts the category' );
is( scalar @{ $fixtures->{events}->created },
    $CREATED_EVENTS, 'create writes an event log row' );
is( scalar @{ $fixtures->{outbox}->created },
    $CREATED_OUTBOX, 'create writes an outbox row' );
is( scalar @{ $fixtures->{audits}->created },
    $CREATED_AUDITS, 'create writes an audit row' );
is( $fixtures->{events}->created->[0]{event_type},
    'category.created', 'event uses the created action' );
is( $fixtures->{audits}->created->[0]{action},
    'category.created', 'audit uses the created action' );
is( $fixtures->{audits}->created->[0]{target_type},
    'category', 'audit targets the category' );

my $repeat = $store->create_category(
    {
        actor_user_id => 'admin-1',
        title         => 'General Discussion',
    }
);
ok( $repeat->{idempotent}, 'create is idempotent for the same space slug' );
is( scalar @{ $fixtures->{categories}->created },
    $CREATED_CATEGORIES, 'idempotent create avoids a second category row' );

my $listed = $store->list_categories( { limit => 10 } );
is( scalar @{$listed},
    $LISTED_CATEGORIES, 'list returns the visible category' );

my $updated = $store->update_category(
    {
        actor_user_id => 'admin-1',
        category_id   => $created->{category_id},
        title         => 'Lounge',
        visibility    => 'members',
    }
);
is( $updated->{title},      'Lounge',  'update stores the new title' );
is( $updated->{visibility}, 'members', 'update stores the new visibility' );
is( $updated->{slug}, 'general-discussion', 'update keeps the existing slug' );
is( $fixtures->{events}->created->[-1]{event_type},
    'category.updated', 'update writes a category.updated event' );

my $missing_space = $store->create_category(
    {
        actor_user_id => 'admin-1',
        space_id      => 'missing-space',
        title         => 'Orphan',
    }
);
ok( !defined $missing_space,
    'create returns undef when a requested space is missing' );

my $missing_category = $store->update_category(
    {
        actor_user_id => 'admin-1',
        category_id   => 'missing-category',
        title         => 'Gone',
    }
);
ok( !defined $missing_category,
    'update returns undef when the category is missing' );

done_testing();

sub _fixtures {
    my $spaces     = _resultset();
    my $categories = _resultset();
    my $events     = _resultset();
    my $outbox     = _resultset();
    my $audits     = _resultset();

    return {
        audits     => $audits,
        categories => $categories,
        events     => $events,
        outbox     => $outbox,
        spaces     => $spaces,
        schema     => GPForum::Test::ModerationSchema->new(
            resultsets => {
                AuditLog      => $audits,
                Category      => $categories,
                EventLog      => $events,
                OutboxMessage => $outbox,
                Space         => $spaces,
            },
        ),
    };
}

sub _resultset {
    return GPForum::Test::ModerationResultSet->new( filter_search => 1 );
}

1;
