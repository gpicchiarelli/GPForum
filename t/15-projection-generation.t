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

const my $EXPECTED_TESTS => 24;

plan tests => $EXPECTED_TESTS;

my $resultset = GPForum::Test::ProjectionGenerationResultSet->new;
my $schema    = GPForum::Test::ProjectionGenerationSchema->new(
    generation_resultset => $resultset, );
my $manager = GPForum::Service::Projection::GenerationManager->new(
    schema     => $schema,
    clock      => GPForum::Test::FixedClock->new,
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

my $ready = $manager->mark_ready('generated-1');

is( $ready->{generation_id}, 'generated-1', 'ready result has id' );
is( $ready->{status},        'ready',       'generation is marked ready' );
is( $resultset->find('generated-1')->get_column('status'),
    'ready', 'stored generation status is ready' );

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

my $failed = $manager->mark_failed('generated-1');

is( $failed->{status}, 'failed', 'generation can be marked failed' );

1;
