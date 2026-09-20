package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Projection::GenerationManager;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ProjectionGenerationResultSet;
use GPForum::Test::ProjectionGenerationRow;
use GPForum::Test::ProjectionGenerationSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 46;

plan tests => $EXPECTED_TESTS;

my $resultset = GPForum::Test::ProjectionGenerationResultSet->new;
my $schema    = GPForum::Test::ProjectionGenerationSchema->new(
    generation_resultset => $resultset, );
my $clock   = GPForum::Test::FixedClock->new;
my $manager = GPForum::Service::Projection::GenerationManager->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);

my $generation = $manager->start_generation(
    'search',
    {
        event_id         => 'event-10',
        event_created_at => '2026-05-23T11:55:00Z',
    }
);

is( $generation->{generation_id}, 'generated-1', 'generation id is generated' );
is( $generation->{projection_name},
    'search', 'generation records projection name' );
is( $generation->{built_from_event_id},
    'event-10', 'generation records source event id' );
is( $generation->{built_from_event_created_at},
    '2026-05-23T11:55:00Z', 'generation records source event time' );
is( $generation->{status},    'building', 'generation starts building' );
is( $generation->{is_active}, 0,          'generation starts inactive' );
is( $generation->{created_at},
    '2026-05-23T12:00:00Z', 'generation records creation time' );
ok(
    !defined $generation->{activated_at},
    'generation does not start activated'
);
is( scalar @{ $resultset->created }, 1, 'generation row is created' );

my $same_generation = $manager->start_generation(
    'search',
    {
        event_created_at => '2026-05-23T11:55:00Z',
        event_id         => 'event-10',
    }
);
ok( $same_generation->{skipped},
    'already-started generation skip does not insert a second row' );
is( $same_generation->{generation_id},
    'generated-1', 'already-started generation keeps the original id' );
is( scalar @{ $resultset->created },
    1, 'already-started generation does not insert a second row' );

$resultset->skip_search(1);
my $raced_generation = $manager->start_generation(
    'search',
    {
        event_created_at => '2026-05-23T11:56:00Z',
        event_id         => 'event-10',
    }
);
ok( $raced_generation->{skipped},
    'unique generation source race reuses the projection event' );

my $generation_pk_rows = GPForum::Test::ProjectionGenerationResultSet->new;
$generation_pk_rows->create(
    {
        built_from_event_id => 'other-event',
        generation_id       => 'generated-1',
        projection_name     => 'other',
        status              => 'building',
    }
);
my $generation_pk_store = GPForum::Service::Projection::GenerationManager->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ProjectionGenerationSchema->new(
        generation_resultset => $generation_pk_rows,
    ),
);
my $generation_pk = $generation_pk_store->start_generation(
    'search',
    {
        event_created_at => '2026-05-23T11:55:00Z',
        event_id         => 'event-pk',
    }
);
ok( !$generation_pk->{skipped},
    'unique generation id collision remints and starts' );
is( $generation_pk->{generation_id},
    'generated-2', 'unique generation id collision remints the id' );
is( $generation_pk->{projection_name},
    'search', 'unique generation id collision keeps this projection' );
is( $generation_pk->{built_from_event_id},
    'event-pk', 'unique generation id collision keeps this source event' );

my $generation_leftover_rows =
  GPForum::Test::ProjectionGenerationResultSet->new;
$generation_leftover_rows->create(
    {
        built_from_event_id => 'event-leftover',
        generation_id       => 'generated-1',
        projection_name     => 'search',
        status              => 'building',
    }
);
$generation_leftover_rows->skip_search(1);
my $generation_leftover_store =
  GPForum::Service::Projection::GenerationManager->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ProjectionGenerationSchema->new(
        generation_resultset => $generation_leftover_rows,
    ),
  );
my $generation_leftover = $generation_leftover_store->start_generation(
    'search',
    {
        event_created_at => '2026-05-23T11:55:00Z',
        event_id         => 'event-leftover',
    }
);
ok( $generation_leftover->{skipped},
    'leftover generation id race reuses this generation' );
is( $generation_leftover->{generation_id},
    'generated-1', 'leftover generation id race keeps this generation' );
is( $generation_leftover->{projection_name},
    'search', 'leftover generation id race keeps this projection' );
is( scalar @{ $generation_leftover_rows->created },
    1, 'leftover generation id race does not insert a second generation' );

my $ready = $manager->mark_ready('generated-1');

is( $ready->{generation_id}, 'generated-1', 'ready result has id' );
is( $ready->{status},        'ready',       'generation is marked ready' );
is( $resultset->find('generated-1')->get_column('status'),
    'ready', 'stored generation status is ready' );
my $ready_updates = scalar @{ $resultset->find('generated-1')->updates };
my $same_ready    = $manager->mark_ready('generated-1');
ok( $same_ready->{skipped}, 'already-ready generation skips the status write' );
is( scalar @{ $resultset->find('generated-1')->updates },
    $ready_updates, 'already-ready generation does not restamp the row' );

my $active_old = GPForum::Test::ProjectionGenerationRow->new(
    data => {
        generation_id   => 'old-generation',
        projection_name => 'search',
        is_active       => 1,
        status          => 'active',
    }
);
$resultset->rows->{'old-generation'} = $active_old;

my $activated = $manager->activate_generation('generated-1');

is( $activated->{generation_id},
    'generated-1', 'activation result has generation id' );
is( $activated->{projection_name},
    'search', 'activation result has projection name' );
is( $activated->{retired_generations},
    1, 'activation retires previous active generation' );
is( $activated->{status}, 'active', 'activation result is active' );
is( $resultset->find('generated-1')->get_column('is_active'),
    1, 'new generation is active' );
is( $resultset->find('generated-1')->get_column('status'),
    'active', 'new generation status is active' );
is( $resultset->find('generated-1')->get_column('activated_at'),
    '2026-05-23T12:00:00Z', 'new generation records activation time' );
is( $active_old->get_column('is_active'), 0,
    'previous generation is inactive' );
is( $active_old->get_column('status'),
    'retired', 'previous generation is retired' );
is( $resultset->last_query->{projection_name},
    'search', 'activation searches active generations by projection' );
is( $resultset->last_query->{is_active},
    1, 'activation searches only active generations' );
my $held_activated =
  $resultset->find('generated-1')->get_column('activated_at');
$clock->iso8601('2026-05-23T13:00:00Z');
my $same_active = $manager->activate_generation('generated-1');
ok( $same_active->{skipped}, 'already-active generation skips reactivation' );
is( $resultset->find('generated-1')->get_column('activated_at'),
    $held_activated, 'already-active generation keeps activated_at' );

my $follow_on = $manager->start_generation(
    'search',
    {
        event_id         => 'event-11',
        event_created_at => '2026-05-23T12:05:00Z',
    }
);
is( $follow_on->{generation_id},
    'generated-3', 'follow-on generation id is generated' );
$resultset->skip_search(1);
my $raced_active = $manager->activate_generation('generated-3');
ok( !$raced_active->{skipped}, 'unique one-active race retries the cutover' );
is( $resultset->find('generated-3')->get_column('is_active'),
    1, 'unique one-active race activates the requested generation' );
is( $resultset->find('generated-1')->get_column('is_active'),
    0, 'unique one-active race retires the previous winner' );

my $failed = $manager->mark_failed('generated-1');

is( $failed->{status}, 'failed', 'generation can be marked failed' );
my $fail_updates = scalar @{ $resultset->find('generated-1')->updates };
my $same_failed  = $manager->mark_failed('generated-1');
ok( $same_failed->{skipped},
    'already-failed generation skips the status write' );
is( scalar @{ $resultset->find('generated-1')->updates },
    $fail_updates, 'already-failed generation does not restamp the row' );

1;
