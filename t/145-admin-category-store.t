# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

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
is( scalar @{ $fixtures->{events}->created },
    $CREATED_EVENTS, 'idempotent create avoids a second event' );

$fixtures->{categories}->skip_search(1);
my $raced = $store->create_category(
    {
        actor_user_id => 'admin-1',
        title         => 'General Discussion',
    }
);
ok( $raced->{idempotent}, 'unique category race reuses the existing slug' );
is( scalar @{ $fixtures->{categories}->created },
    $CREATED_CATEGORIES, 'unique category race does not insert a second row' );
is( scalar @{ $fixtures->{events}->created },
    $CREATED_EVENTS, 'unique category race does not write a second event' );
is( scalar @{ $fixtures->{audits}->created },
    $CREATED_AUDITS, 'unique category race does not write a second audit' );

my $category_pk_spaces     = _resultset();
my $category_pk_categories = _resultset();
$category_pk_spaces->create(
    {
        slug     => 'general',
        space_id => 'space-1',
        title    => 'General',
    }
);
$category_pk_categories->create(
    {
        category_id => 'generated-1',
        slug        => 'other-board',
        space_id    => 'other-space',
        title       => 'Other',
    }
);
my $category_pk_store = GPForum::Service::Admin::CategoryStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog      => _resultset(),
            Category      => $category_pk_categories,
            EventLog      => _resultset(),
            OutboxMessage => _resultset(),
            Space         => $category_pk_spaces,
        },
    ),
);
my $category_pk = $category_pk_store->create_category(
    {
        actor_user_id => 'admin-1',
        space_id      => 'space-1',
        title         => 'General Discussion',
    }
);
ok( !$category_pk->{idempotent},
    'unique category id collision remints and creates' );
is( $category_pk->{category_id},
    'generated-2', 'unique category id collision remints the id' );
is( $category_pk->{slug}, 'general-discussion',
    'unique category id collision keeps this slug' );
is( $category_pk->{space_id},
    'space-1', 'unique category id collision keeps this space' );

my $category_leftover_spaces     = _resultset();
my $category_leftover_categories = _resultset();
$category_leftover_spaces->create(
    {
        slug     => 'general',
        space_id => 'space-1',
        title    => 'General',
    }
);
$category_leftover_categories->create(
    {
        category_id => 'generated-1',
        slug        => 'general-discussion',
        space_id    => 'space-1',
        title       => 'General Discussion',
    }
);
$category_leftover_categories->skip_search(1);
my $category_leftover_events = _resultset();
my $category_leftover_outbox = _resultset();
my $category_leftover_audits = _resultset();
my $category_leftover_store  = GPForum::Service::Admin::CategoryStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog      => $category_leftover_audits,
            Category      => $category_leftover_categories,
            EventLog      => $category_leftover_events,
            OutboxMessage => $category_leftover_outbox,
            Space         => $category_leftover_spaces,
        },
    ),
);
my $category_leftover = $category_leftover_store->create_category(
    {
        actor_user_id => 'admin-1',
        space_id      => 'space-1',
        title         => 'General Discussion',
    }
);
ok( $category_leftover->{idempotent},
    'leftover category id race reuses this category' );
is( $category_leftover->{category_id},
    'generated-1', 'leftover category id race keeps this category' );
is( $category_leftover->{slug},
    'general-discussion', 'leftover category id race keeps this slug' );
is( scalar @{ $category_leftover_categories->created },
    1, 'leftover category id race does not insert a second category' );
is( scalar @{ $category_leftover_events->created },
    1, 'leftover category id race inserts the missing event' );
is( scalar @{ $category_leftover_outbox->created },
    1, 'leftover category id race inserts the missing outbox' );
is( scalar @{ $category_leftover_audits->created },
    1, 'leftover category id race inserts the missing audit' );

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
my $event_count  = scalar @{ $fixtures->{events}->created };
my $audit_count  = scalar @{ $fixtures->{audits}->created };
my $outbox_count = scalar @{ $fixtures->{outbox}->created };
my $same         = $store->update_category(
    {
        actor_user_id => 'admin-1',
        category_id   => $created->{category_id},
        title         => 'Lounge',
        visibility    => 'members',
    }
);
ok( $same->{skipped}, 'unchanged category update is skipped' );
is( $same->{title},      'Lounge',  'unchanged category keeps the title' );
is( $same->{visibility}, 'members', 'unchanged category keeps visibility' );
is( $same->{version}, $updated->{version},
    'unchanged category does not bump version' );
is( scalar @{ $fixtures->{events}->created },
    $event_count, 'unchanged category does not write another event' );
is( scalar @{ $fixtures->{audits}->created },
    $audit_count, 'unchanged category does not write another audit' );
is( scalar @{ $fixtures->{outbox}->created },
    $outbox_count, 'unchanged category does not write another outbox row' );

my $announcements = $store->create_category(
    {
        actor_user_id => 'admin-1',
        title         => 'Announcements',
    }
);
is( $announcements->{space_id},
    'generated-1', 'second category reuses the existing default space' );
is( scalar @{ $fixtures->{spaces}->created },
    $CREATED_SPACES, 'second category does not insert a second space' );

$fixtures->{spaces}->skip_search(2);
my $raced_space = $store->create_category(
    {
        actor_user_id => 'admin-1',
        title         => 'Staff',
    }
);
is( $raced_space->{space_id},
    'generated-1', 'unique space race reuses the default space id' );
is( scalar @{ $fixtures->{spaces}->created },
    $CREATED_SPACES, 'unique space race does not insert a second space' );

my $space_pk_spaces = _resultset();
$space_pk_spaces->create(
    {
        slug     => 'other',
        space_id => 'generated-1',
        title    => 'Other',
    }
);
$space_pk_spaces->skip_search(2);
my $space_pk_store = GPForum::Service::Admin::CategoryStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog      => _resultset(),
            Category      => _resultset(),
            EventLog      => _resultset(),
            OutboxMessage => _resultset(),
            Space         => $space_pk_spaces,
        },
    ),
);
my $space_pk = $space_pk_store->create_category(
    {
        actor_user_id => 'admin-1',
        title         => 'General Discussion',
    }
);
ok( !$space_pk->{idempotent}, 'unique space id collision remints and creates' );
is( $space_pk->{space_id},
    'generated-2', 'unique space id collision remints the id' );
is( $space_pk->{slug}, 'general-discussion',
    'unique space id collision still creates this category' );
is( scalar @{ $space_pk_spaces->created },
    2, 'unique space id collision inserts the reminted default space' );

my $space_leftover_spaces = _resultset();
$space_leftover_spaces->create(
    {
        slug     => 'general',
        space_id => 'generated-1',
        title    => 'General',
    }
);
$space_leftover_spaces->skip_search(2);
my $space_leftover_store = GPForum::Service::Admin::CategoryStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog      => _resultset(),
            Category      => _resultset(),
            EventLog      => _resultset(),
            OutboxMessage => _resultset(),
            Space         => $space_leftover_spaces,
        },
    ),
);
my $space_leftover = $space_leftover_store->create_category(
    {
        actor_user_id => 'admin-1',
        title         => 'General Discussion',
    }
);
is( $space_leftover->{space_id},
    'generated-1', 'leftover space id race reuses this space' );
is( $space_leftover->{slug},
    'general-discussion',
    'leftover space id race still creates this category' );
is( scalar @{ $space_leftover_spaces->created },
    1, 'leftover space id race does not insert a second space' );
ok( !$space_leftover->{idempotent},
    'leftover space id race still writes this category' );

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
