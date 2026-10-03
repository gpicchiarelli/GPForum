# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::Log;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Notification::Dispatcher;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Realtime::PgNotifier;
use GPForum::Test::BadgeBroadcastSpy;
use GPForum::Test::CancelledCountSchema;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::NotificationResultSet;
use GPForum::Test::NotificationTxnSchema;
use GPForum::Test::PermissionEngine;
use GPForum::Test::StatementTimeoutReadability;

our $VERSION = '0.001';

const my $HTTP_OK         => 200;
const my $FIXED_NOW       => '2026-05-23T12:00:00Z';
const my $NOTIFICATION_ID => '0f8e2b1c-6d3a-4f5e-9a7b-1c2d3e4f5a6b';
const my $STATEMENT_TIMEOUT =>
  GPForum::Test::StatementTimeoutReadability->message;
const my $WARNINGS_FOR_TWO_MESSAGES => 2;
const my $FAILED_BADGES             => 6;
const my $FAILED_BADGES_IN_APP      => 2;
const my $WARNINGS_IN_THE_OUTAGES   => 3;
const my $LOG_INTERVAL              => 300;
const my $INTERLEAVED_ROUNDS        => 5;
const my $ERROR_TEXT_LIMIT          => 300;
const my $PADDING_BEFORE_SECRET     => 285;
const my $REMEMBERED_MESSAGES       => 32;
const my $CONNECT_FAILED =>
  q{DBIx::Class::Storage::DBI::catch {...} (): DBI Connection failed: }
  . q{DBI connect('dbname=forum;host=db.internal;password=sekrit',}
  . q{'gpforum',...) failed: connection to server at "db.internal", port}
  . q{ 5432 failed: Connection refused};

# Bootstrap builds a dispatcher per request. A failed badge was counted on
# the process and logged on every request, so an outage that failed each
# badge the same way wrote a warning per request; and since the dispatcher
# Bootstrap built had no logger and /metrics did not read the counter, it
# was logged nowhere and reported nowhere.
my $inbox  = GPForum::Test::NotificationResultSet->new;
my $schema = GPForum::Test::NotificationTxnSchema->new(
    resultsets => {
        Notification      => GPForum::Test::NotificationResultSet->new,
        NotificationInbox => $inbox,
        NotificationRead  => GPForum::Test::NotificationResultSet->new,
    },
);
my $clock       = GPForum::Test::FixedClock->new;
my $readability = GPForum::Test::StatementTimeoutReadability->new;
my $badges      = GPForum::Test::BadgeBroadcastSpy->new( schema => $schema );
my $log         = Mojo::Log->new( level => 'warn' );
my $warnings    = $log->capture('warn');
my %stats       = ( badge_failures => 0 );
my %badge_errors;

# What one process shares between the dispatchers its requests build.
my $per_request = sub {
    my (%overrides) = @_;

    return GPForum::Service::Notification::Dispatcher->new(
        badge_errors      => \%badge_errors,
        clock             => $clock,
        id_service        => GPForum::Test::Id->new,
        logger            => $log,
        permission_engine => GPForum::Test::PermissionEngine->new,
        readability       => $readability,
        realtime_notifier => $badges,
        schema            => $schema,
        stats             => \%stats,
        %overrides,
    );
};

my %notification_of;
for my $user_id (qw(user-1 user-2 user-3)) {
    my $delivered = $per_request->()->create_notification(
        {
            notification_type => 'reply',
            payload           => { thread_id => "thread-$user_id" },
            recipient_user_id => $user_id,
            source_id         => "post-$user_id",
            source_type       => 'post',
        }
    );
    $notification_of{$user_id} = $delivered->{notification}{notification_id};
}
is( _badge_warnings($warnings), 0, 'badges that go out log nothing' );
is( $per_request->()->snapshot->{last_badge_error},
    undef, 'and leave no last badge failure' );

$readability->fail(1);
for my $user_id (qw(user-1 user-2 user-3)) {
    my $read =
      $per_request->()->mark_read( $notification_of{$user_id}, $user_id );
    ok(
        $read->{ok} && !defined $read->{unread_count},
        "${user_id}'s read stands without a count"
    );
}
is(
    $stats{badge_failures},
    scalar keys %notification_of,
    'every badge that could not be counted is counted'
);
is( _badge_warnings($warnings),
    1, 'but one outage, failing every request the same way, logs once' );
unlike( "$warnings", qr/ParamValues|user-2/msx,
    'without the statement and bind values that name the member' );
like(
    "$warnings",
    qr/badge [ ] not [ ] sent: [ ] \Q$STATEMENT_TIMEOUT\E $/msx,
    'with the error itself'
);
is_deeply(
    $per_request->()->snapshot,
    {
        badge_failures   => scalar keys %notification_of,
        last_badge_error => { at => $FIXED_NOW, message => $STATEMENT_TIMEOUT },
    },
    'the snapshot carries the count and the last failure'
);

$readability->fail(0);
my $unsent = $per_request->(
    realtime_notifier => GPForum::Service::Realtime::PgNotifier->new );
$unsent->mark_read( $notification_of{'user-1'}, 'user-1' );
is( _badge_warnings($warnings),
    $WARNINGS_FOR_TWO_MESSAGES, 'a failure with another message is logged' );
like(
    $unsent->snapshot->{last_badge_error}{message},
    qr/\A badge [ ] NOTIFY [ ] failed: /msx,
    'and becomes the last failure'
);

# A badge that goes out does not end the outage: under load some counts
# still finish, and re-arming the warning on each of them logged nearly
# every failure.
$per_request->()->mark_read( $notification_of{'user-2'}, 'user-2' );
$readability->fail(1);
$per_request->()->mark_read( $notification_of{'user-3'}, 'user-3' );
is( _badge_warnings($warnings),
    $WARNINGS_FOR_TWO_MESSAGES,
    'a badge that goes out in between does not log the same failure again' );
$clock->epoch( $clock->epoch + $LOG_INTERVAL );
$per_request->()->mark_read( $notification_of{'user-1'}, 'user-1' );
is( _badge_warnings($warnings),
    $WARNINGS_IN_THE_OUTAGES, 'five minutes on, it is logged again' );
my $three_more = qr/[(]3 [ ] more [ ] since [ ] last [ ] logged[)]/msx;
like(
    "$warnings",
    qr/\Q$STATEMENT_TIMEOUT\E [ ] $three_more $/msx,
    'with how many failed the same way in between'
);
$per_request->()->mark_read( $notification_of{'user-2'}, 'user-2' );
is( _badge_warnings($warnings), $WARNINGS_IN_THE_OUTAGES, 'and then once' );
is(
    $stats{badge_failures},
    $FAILED_BADGES + 1,
    'each failure is still counted'
);

# A fanout in a partial outage: every other recipient's count fails.
my $interleaved_log      = Mojo::Log->new( level => 'warn' );
my $interleaved_warnings = $interleaved_log->capture('warn');
my %interleaved_errors;
my $interleaved = sub {
    my (%overrides) = @_;

    return $per_request->(
        badge_errors => \%interleaved_errors,
        logger       => $interleaved_log,
        stats        => { badge_failures => 0 },
        %overrides,
    );
};
for ( 1 .. $INTERLEAVED_ROUNDS ) {
    $readability->fail(1);
    $interleaved->()->mark_read( $notification_of{'user-1'}, 'user-1' );
    $readability->fail(0);
    $interleaved->()->mark_read( $notification_of{'user-2'}, 'user-2' );
}
is( _badge_warnings($interleaved_warnings),
    1, 'failures interleaved with badges that go out are logged once' );

# Two failures taking turns, a count and a NOTIFY, are each logged once.
my $unsent_notifier = GPForum::Service::Realtime::PgNotifier->new;
for ( 1 .. $INTERLEAVED_ROUNDS ) {
    $readability->fail(1);
    $interleaved->()->mark_read( $notification_of{'user-1'}, 'user-1' );
    $readability->fail(0);
    $interleaved->( realtime_notifier => $unsent_notifier )
      ->mark_read( $notification_of{'user-2'}, 'user-2' );
}
is( _badge_warnings($interleaved_warnings),
    $WARNINGS_FOR_TWO_MESSAGES, 'and two failures taking turns once each' );
undef $interleaved_warnings;

# A count that cannot reconnect fails with DBI's connect error, which
# repeats the DSN: an inline password went to the log and /metrics.
my $connect_log      = Mojo::Log->new( level => 'warn' );
my $connect_warnings = $connect_log->capture('warn');
my $reconnecting     = $per_request->(
    badge_errors => {},
    logger       => $connect_log,
    stats        => { badge_failures => 0 },
);
$readability->fail_with(
    "$CONNECT_FAILED\n\tIs the server running on that host? at x line 1.\n");
$reconnecting->mark_read( $notification_of{'user-1'}, 'user-1' );
unlike( "$connect_warnings", qr/sekrit/msx,
    'a password in the DSN DBI repeats is not logged' );
my $dsn = qr/'dbname=forum;host=db[.]internal;/msx;
like(
    "$connect_warnings",
    qr/connect[(] $dsn password=\[redacted\] [ ]/msx,
    'it is redacted as the settings page redacts it'
);
unlike( $reconnecting->snapshot->{last_badge_error}{message},
    qr/sekrit/msx, 'nor reported' );

# Redacted before it is cut, so the cut cannot leave half of it.
$readability->fail_with(
    ( 'x' x $PADDING_BEFORE_SECRET ) . " password=sekritsekrit\n" );
$reconnecting->mark_read( $notification_of{'user-1'}, 'user-1' );
my $long = $reconnecting->snapshot->{last_badge_error}{message};
is( length $long, $ERROR_TEXT_LIMIT, 'a long error is cut' );
unlike( $long, qr/sekr/msx, 'after its password is redacted' );

$readability->fail_with("\n  \nsecond line says it\n");
$reconnecting->mark_read( $notification_of{'user-1'}, 'user-1' );
is(
    $reconnecting->snapshot->{last_badge_error}{message},
    'second line says it',
    'a blank first line is skipped'
);
undef $connect_warnings;

# The messages logged are remembered within a bound: errors that each read
# differently would otherwise grow the process's memory without end.
my %bounded_errors;
my $bounded_log      = Mojo::Log->new( level => 'warn' );
my $bounded_warnings = $bounded_log->capture('warn');
my $bounded          = $per_request->(
    badge_errors => \%bounded_errors,
    logger       => $bounded_log,
    stats        => { badge_failures => 0 },
);
for my $nth ( 1 .. $REMEMBERED_MESSAGES ) {
    $readability->fail_with("error $nth\n");
    $bounded->mark_read( $notification_of{'user-1'}, 'user-1' );
}
is( scalar keys %{ $bounded_errors{logged} },
    $REMEMBERED_MESSAGES, 'each message is remembered up to the bound' );
$readability->fail_with("error 0\n");
$bounded->mark_read( $notification_of{'user-1'}, 'user-1' );
is( scalar keys %{ $bounded_errors{logged} },
    1, 'past it, when none is stale, all of them are forgotten' );
$readability->fail_with("error 1\n");
$bounded->mark_read( $notification_of{'user-1'}, 'user-1' );
is(
    _badge_warnings($bounded_warnings),
    $REMEMBERED_MESSAGES + 2,
    'and a forgotten one is logged again'
);
$clock->epoch( $clock->epoch + $LOG_INTERVAL );

for my $nth ( 2 .. $REMEMBERED_MESSAGES ) {
    $readability->fail_with("error $nth\n");
    $bounded->mark_read( $notification_of{'user-1'}, 'user-1' );
}
is_deeply(
    [ sort keys %{ $bounded_errors{logged} } ],
    [ sort map { "error $_" } 2 .. $REMEMBERED_MESSAGES ],
    'past it, the stale ones go first and the recent ones stay'
);
$readability->fail_with(undef);
undef $bounded_warnings;

# The metrics snapshot reports the dispatcher's counters.
is_deeply(
    GPForum::Service::Operations::MetricsSnapshot->new(
        notification_dispatcher => $per_request->()
    )->collect->{notifications},
    $per_request->()->snapshot,
    'the metrics snapshot reports the dispatcher\'s counters as notifications'
);
is_deeply(
    GPForum::Service::Operations::MetricsSnapshot->new->collect
      ->{notifications},
    {},
    'and an empty section without a dispatcher'
);

# The forum fakes stand in for the dispatcher with no counters: /metrics
# answered 500 with one.
my $counterless = bless {}, 'GPForum::Test::CounterlessDispatcher';
is_deeply(
    GPForum::Service::Operations::MetricsSnapshot->new(
        notification_dispatcher => $counterless
    )->collect->{notifications},
    {},
    'or with a dispatcher that keeps no counters'
);

# The application: the dispatcher Bootstrap builds -- per request, and for
# the worker's notification handler -- logs through the application log,
# and /metrics reads the process's counters. The schema's inbox finds the
# notification, already read; the count's readability lookup is cancelled.
my $test = Test::Mojo->new('GPForum');
my $app  = $test->app;
$app->log->level('fatal');
my $cancelled_schema = GPForum::Test::CancelledCountSchema->new;
$app->helper( gp_schema => sub { return $cancelled_schema; } );
my $app_badges = GPForum::Test::BadgeBroadcastSpy->new;
$app->helper( gp_realtime_pg_notifier => sub { return $app_badges; } );

my $controller = $app->build_controller;
is( $controller->gp_notification_dispatcher->logger,
    $app->log,
    'the dispatcher Bootstrap builds logs through the application log' );
my ($worker_handler) =
  grep { $_->isa('GPForum::Worker::Handler::NotificationDispatch') }
  @{ $controller->gp_outbox_transport->handlers };
is( $worker_handler->dispatcher->logger,
    $app->log, 'and so does the worker\'s fanout' );

$test->get_ok('/metrics')
  ->status_is($HTTP_OK)
  ->json_has( '/notifications/badge_failures',
    '/metrics carries the badge failures' );
my $failures_before = $test->tx->res->json('/notifications/badge_failures');

my $app_warnings = $app->log->capture('warn');
for ( 1 .. $FAILED_BADGES_IN_APP ) {
    my $read = $app->build_controller->gp_notification_dispatcher->mark_read(
        $NOTIFICATION_ID, 'user-1' );
    ok(
        $read->{ok} && !defined $read->{unread_count},
        'a read whose count fails answers ok, without a count'
    );
}
is( _badge_warnings($app_warnings),
    1, 'the failed count is logged in the application log, once' );
like(
    "$app_warnings",
    qr/badge [ ] not [ ] sent: [ ] \Q$STATEMENT_TIMEOUT\E $/msx,
    'with its error'
);
undef $app_warnings;

$test->get_ok('/metrics')->status_is($HTTP_OK);
$test->json_is(
    '/notifications/badge_failures' => $failures_before + $FAILED_BADGES_IN_APP,
    '/metrics counts every badge that failed in the process'
);
$test->json_is(
    '/notifications/last_badge_error/message' => $STATEMENT_TIMEOUT,
    'and says what failed'
);
is( scalar @{ $app_badges->badges }, 0, 'no badge went out without a count' );

done_testing();

sub _badge_warnings {
    my ($captured) = @_;

    my @lines = "$captured" =~ /notification [ ] badge [ ] not [ ] sent/gmsx;

    return scalar @lines;
}

1;
