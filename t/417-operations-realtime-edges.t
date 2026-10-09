# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;
use utf8;

use Const::Fast;
use Test::More;

use lib 'lib';

use GPForum::Runtime;
use GPForum::Service::Operations::DbQueryStats;
use GPForum::Service::Operations::DeadLetterCheck::ProbeClock;
use GPForum::Service::Operations::DeadLetterCheck::ProbeOutbox;
use GPForum::Service::Operations::DeadLetterCheck::ProbeRow;
use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::ConnectionRegistry;

our $VERSION = '0.001';

const my $UNREACHABLE_WORKERS => 99;
const my $CONNECTION_LIMIT    => 2;
const my $RETRY_SECONDS       => 60;
const my $HTTP_CREATED        => 201;

# The dead-letter check's in-memory outbox answers the dispatcher's claim
# query as PostgreSQL would: equality, -in, <= on the timestamp (inclusive),
# any arm of an OR, and the row limit.
my @rows = map {
    GPForum::Service::Operations::DeadLetterCheck::ProbeRow->new(
        data => {
            outbox_id       => "probe-$_->[0]",
            status          => $_->[1],
            next_attempt_at => $_->[2],
        }
    )
} (
    [ q{a}, 'pending', '2026-09-21T12:00:00Z' ],
    [ q{b}, 'failed',  '2026-09-21T11:00:00Z' ],
    [ q{c}, 'pending', '2026-09-21T12:00:01Z' ],
    [ q{d}, 'done',    '2026-09-21T10:00:00Z' ],
);
my $outbox =
  GPForum::Service::Operations::DeadLetterCheck::ProbeOutbox->new(
    rows => \@rows );
my $due = {
    status          => { -in  => [qw(pending failed)] },
    next_attempt_at => { '<=' => '2026-09-21T12:00:00Z' },
};
is_deeply( [ _ids( $outbox->search_rs( $due, {} ) ) ],
    [qw(probe-a probe-b)], 'due rows: -in and an inclusive <=' );
is_deeply( [ _ids( $outbox->search_rs( $due, { rows => 1 } ) ) ],
    ['probe-a'], 'cut to the row limit, in order' );
is_deeply(
    [
        _ids(
            $outbox->search_rs(
                [ { outbox_id => 'probe-d' }, { status => 'failed' } ], {}
            )
        )
    ],
    [qw(probe-b probe-d)],
    'a list of conditions matches any of them'
);
my $clock = GPForum::Service::Operations::DeadLetterCheck::ProbeClock->new;
isnt( $clock->epoch_plus_iso8601($RETRY_SECONDS),
    $clock->now_iso8601, 'the probe clock puts a retry after now' );
is( $clock->epoch_plus_iso8601(0), $clock->now_iso8601, 'and no delay at now' );

# OS preflight starts from the runtime's own settings; an attribute given to
# the check wins over them.
my $runtime = GPForum::Runtime->new( os_preflight_settings =>
      { min_recommended_workers => $UNREACHABLE_WORKERS } );
is(
    _check_status(
        GPForum::Service::Operations::OSPreflight->new( runtime => $runtime ),
        'recommended_worker_count'
    ),
    'degraded',
    q{the runtime's worker threshold is applied}
);
is(
    _check_status(
        GPForum::Service::Operations::OSPreflight->new(
            runtime                 => $runtime,
            min_recommended_workers => 1,
        ),
        'recommended_worker_count'
    ),
    'ok',
    'unless the check is given its own'
);

# A finished request keeps the route, endpoint and status it was given.
my $stats = GPForum::Service::Operations::DbQueryStats->new;
my $token = $stats->start_request( { route => 'unknown' } );
my $finished =
  $stats->finish_request( $token,
    { route => '/t', endpoint_name => 'thread', status => $HTTP_CREATED } );
is_deeply(
    [ @{$finished}{qw(route endpoint_name status)} ],
    [ '/t', 'thread', $HTTP_CREATED ],
    'a finished request records its route, endpoint and status'
);

# A member may hold max_connections_per_user sockets, and no more.
my $registry = GPForum::Service::Realtime::ConnectionRegistry->new(
    max_connections_per_user => $CONNECTION_LIMIT );
my $member = { user_id => 'user-1' };
ok( $registry->register( 'socket-1',  $member, undef ), 'a first socket' );
ok( $registry->register( 'socket-2',  $member, undef ), 'a second' );
ok( !$registry->register( 'socket-3', $member, undef ),
    'but not one over the limit' );
ok( $registry->can_register( { user_id => 'user-2' } ),
    'which counts per member' );

# A channel is a lower-case type, a colon, and an id of letters, digits,
# _, . and -.
for my $case (
    [
        'thread:0192-ab_c.d', { type => 'thread', resource_id => '0192-ab_c.d' }
    ],
    [ 'thread2:x',  { type => 'thread2', resource_id => 'x' } ],
    [ 'Thread:x',   undef ],
    [ 'thread:x y', undef ],
    [ q{thread:é},  undef, q{a channel id that is not ASCII} ],
  )
{
    my ( $channel, $expected, $name ) = @{$case};
    my $parsed =
      GPForum::Service::Realtime::ChannelAuthorizer::parse_channel($channel);
    is_deeply(
        $parsed
        ? { type => $parsed->{type}, resource_id => $parsed->{resource_id} }
        : undef,
        $expected,
        $name // "channel $channel"
    );
}

done_testing();

sub _ids ($search) {
    return map { $_->get_column('outbox_id') } $search->all;
}

sub _check_status ( $preflight, $name ) {
    my ($check) = grep { $_->{name} eq $name } @{ $preflight->check->{checks} };

    return $check->{status};
}

1;
