package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Projection::OffsetTracker;
use GPForum::Test::FixedClock;
use GPForum::Test::ProjectionOffsetResultSet;
use GPForum::Test::ProjectionSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 20;
const my $EVENT_EPOCH    => 1_716_463_940;
const my $EXPECTED_LAG   => 60;

plan tests => $EXPECTED_TESTS;

my $resultset = GPForum::Test::ProjectionOffsetResultSet->new;
my $schema =
  GPForum::Test::ProjectionSchema->new( offset_resultset => $resultset );
my $tracker = GPForum::Service::Projection::OffsetTracker->new(
    schema => $schema,
    clock  => GPForum::Test::FixedClock->new,
);

my $progress = $tracker->record_progress(
    'search',
    {
        event_id            => 'event-1',
        event_created_at    => '2026-05-23T11:59:00Z',
        event_created_epoch => $EVENT_EPOCH,
    }
);

is( $progress->{projection_name}, 'search',
    'progress records projection name' );
is( $progress->{last_event_id}, 'event-1', 'progress records last event id' );
is( $progress->{last_event_created_at},
    '2026-05-23T11:59:00Z', 'progress records last event timestamp' );
is( $progress->{lag_seconds}, $EXPECTED_LAG, 'progress records lag seconds' );
is( $progress->{status}, 'catching_up', 'lagged projection is catching up' );
is( $progress->{updated_at},
    '2026-05-23T12:00:00Z', 'progress records update time' );
is( scalar @{ $resultset->writes }, 1, 'progress writes one offset row' );

my $observed = $tracker->observe_lag('search');

is( $observed->{projection_name}, 'search',  'lag observation has name' );
is( $observed->{lag_seconds}, $EXPECTED_LAG, 'lag observation has seconds' );
is( $observed->{status},      'catching_up', 'lag observation has status' );
is( $observed->{updated_at},
    '2026-05-23T12:00:00Z', 'lag observation has update timestamp' );

my $current = $tracker->record_progress(
    'notifications',
    {
        event_id         => 'event-2',
        event_created_at => '2026-05-23T12:00:00Z',
    }
);

is( $current->{lag_seconds}, 0,         'current projection has zero lag' );
is( $current->{status},      'current', 'current projection is current' );

my $replayed = $tracker->record_progress(
    'notifications',
    {
        event_id         => 'event-2',
        event_created_at => '2026-05-23T12:00:00Z',
    }
);

is( $replayed->{last_event_id},
    'event-2', 'replayed projection event preserves last event id' );
is( $tracker->observe_lag('notifications')->{last_event_id},
    undef, 'lag observation does not expose canonical event payload' );
is( scalar keys %{ $resultset->rows },
    2, 'projection replay updates one offset row per projection' );

my $failed = $tracker->mark_failed('feed');

is( $failed->{projection_name}, 'feed', 'failed projection has name' );
is( $failed->{status},      'failed',   'failed projection has failed status' );
is( $failed->{lag_seconds}, 0, 'failed projection uses explicit lag value' );
ok(
    !defined $tracker->observe_lag('unknown'),
    'unknown projection has no lag observation'
);

1;
