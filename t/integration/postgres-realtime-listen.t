# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use JSON::MaybeXS qw(encode_json);
use Time::HiRes   qw(sleep);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::PgNotifications;
use GPForum::Service::Operations::CacheInvalidationBus;
use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::ConnectionRegistry;
use GPForum::Service::Realtime::EventEnvelope;
use GPForum::Service::Realtime::Hub;
use GPForum::Service::Realtime::PgListener;
use GPForum::Test::PgDatabase;
use GPForum::Test::PostgresHarness;
use GPForum::Test::RealtimeBadgeCounter;
use GPForum::Test::RealtimeConnection;
use GPForum::Test::RealtimePermissionEngine;

our $VERSION = '0.001';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

const my $CACHE_CHANNEL  => 'gpforum_cache_invalidation';
const my $DOMAIN_CHANNEL => 'gpforum_domain_events';
const my $UNREAD_COUNT   => 3;
const my $ATTEMPTS       => 40;
const my $PAUSE_SECONDS  => 0.05;
const my $SETTLE_SECONDS => 5;

# A web process as Bootstrap wires it: the cache bus and the realtime
# listener on one schema handle, sharing one notification queue. A second
# connection plays the other processes of the cluster.
my $database = GPForum::Test::PgDatabase->fresh;
my $schema   = $database->schema;
my $peer     = GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );
my $queue = GPForum::Infrastructure::PgNotifications->new( schema => $schema );
my $bus   = GPForum::Service::Operations::CacheInvalidationBus->new(
    notifications => $queue,
    schema        => $schema,
);
my $thread   = GPForum::Test::RealtimeConnection->new;
my $badge    = GPForum::Test::RealtimeConnection->new;
my $hub      = _hub( $thread, $badge );
my $listener = GPForum::Service::Realtime::PgListener->new(
    hub           => $hub,
    notifications => $queue,
    schema        => $schema,
);

ok( $listener->start->{ok}, 'the listener starts' );
is( $listener->status, 'listening', 'and LISTENs' );
is_deeply( $bus->drain, [], 'the bus LISTENs on the same handle' );
is_deeply(
    [ sort @{ _listening($schema) } ],
    [ $CACHE_CHANNEL, $DOMAIN_CHANNEL ],
    'one backend listens on both channels'
);

subtest 'each consumer gets only its own channel' => sub {
    _notify_cache( { tags => ['thread:thread-1'] } );
    _notify_event('post-1');
    _notify_cache( { keys => ['public:/t/thread-1'] } );

    my @requests = _eventually( sub { return @{ $bus->drain }; }, 2 );
    is_deeply(
        [ map { [ $_->{tags}, $_->{keys} ] } @requests ],
        [ [ ['thread:thread-1'], [] ], [ [], ['public:/t/thread-1'] ] ],
        'the bus receives both invalidations'
    );
    is( $bus->snapshot->{applied}, 2, 'and no realtime event among them' );

    my @delivered = _eventually( sub { return _deliver($thread); }, 1 );
    is( $delivered[0]{json}{payload}{post_id},
        'post-1', 'the listener delivers its event' );
    is( $listener->snapshot->{malformed_payloads},
        0, 'and rejects no cache purge as malformed' );
};

subtest 'a disconnected handle is listened to again, with a gap' => sub {
    my $before = _backend_pid($schema);
    $schema->storage->disconnect;

    is_deeply(
        $bus->drain,
        [ { clear => 1, keys => [], tags => [] } ],
        'the bus clears L1 once: what was NOTIFYed meanwhile is gone'
    );
    isnt( _backend_pid($schema), $before, 'on a new backend' );
    is_deeply(
        [ sort @{ _listening($schema) } ],
        [ $CACHE_CHANNEL, $DOMAIN_CHANNEL ],
        'which listens on both channels again'
    );

    my $sent = scalar @{ $badge->sent };
    $listener->poll_once;
    is( scalar @{ $badge->sent }, $sent + 1, 'the listener re-sends badges' );
    is( $badge->sent->[-1]{json}{payload}{unread_count},
        $UNREAD_COUNT, 'with the current count' );

    _notify_event('post-2');
    my @delivered = _eventually( sub { return _deliver($thread); }, 1 );
    is( $delivered[0]{json}{payload}{post_id},
        'post-2', 'and delivery resumes' );
};

# The case a PostgreSQL restart or failover makes: the server ends the
# backend, and the handle only finds out when it is next used.
subtest 'a backend the server terminated is replaced the same way' => sub {
    my $before = _backend_pid($schema);

    # DBI warns while it frees the dead handle's cached statements; any
    # other warning is kept and must not happen.
    my @unexpected;
    local $SIG{__WARN__} = sub {
        my ($warning) = @_;
        if ( $warning !~ /no [ ] connection [ ] to [ ] the [ ] server/msx ) {
            push @unexpected, $warning;
        }
    };
    $peer->do( 'SELECT pg_terminate_backend(?)', undef, $before );

    my @requests = _eventually( sub { return @{ $bus->drain }; }, 1 );
    is_deeply(
        \@requests,
        [ { clear => 1, keys => [], tags => [] } ],
        'the bus clears L1'
    );
    isnt( _backend_pid($schema), $before, 'after a reconnect' );

    _notify_cache( { tags => ['thread:thread-2'] } );
    my @after = _eventually( sub { return @{ $bus->drain }; }, 1 );
    is_deeply( $after[0]{tags}, ['thread:thread-2'],
        'and invalidations arrive again' );
    is_deeply( \@unexpected, [], 'with no other warning' );
};

# A new worker -- every deploy, every recycle -- replayed the backstop from
# the oldest retained row.
subtest 'the backstop starts at the head of the outbox' => sub {
    _done_row( 'old-1', q{now() - interval '1 hour'} );
    _done_row( 'old-2', q{now() - interval '1 minute'} );
    my $fresh    = GPForum::Test::RealtimeConnection->new;
    my $backstop = GPForum::Service::Realtime::PgListener->new(
        hub    => _hub( $fresh, GPForum::Test::RealtimeConnection->new ),
        schema => $schema,
    );

    $backstop->poll_once;
    my $head = $backstop->outbox_poll_cursor;
    ok( $head, 'the first poll seeds the cursor' );
    $backstop->poll_once;
    is( scalar @{ $fresh->sent }, 0, 'rows done before it are not replayed' );

    _done_row( 'new-1',
        $peer->quote( $head->{next_attempt_at} )
          . q{::timestamptz + interval '1 millisecond'} );
    sleep $PAUSE_SECONDS;
    $backstop->poll_once;
    is_deeply( [ map { $_->{json}{payload}{post_id} } @{ $fresh->sent } ],
        ['post-new-1'],
        'a row done after the head is read once it has settled' );

    _done_row( 'unsettled', 'statement_timestamp()' );
    $backstop->poll_once;
    is( scalar @{ $fresh->sent }, 1,
        'one done within the settle window waits' );

    # The keyset's OR alone is a filter: the scan started at the first done
    # row and discarded every one before the cursor, a week of them at the
    # head of a busy forum, once a second in every worker with sockets.
    like(
        _plan( $backstop->outbox_poll_resultset ),
        qr/Index [ ] Cond: [^\n]* next_attempt_at [ ] >= /msx,
        'the index range starts at the cursor'
    );
};

done_testing();

sub _hub {
    my ( $thread_connection, $badge_connection ) = @_;

    my $realtime_hub = GPForum::Service::Realtime::Hub->new(
        authorizer => GPForum::Service::Realtime::ChannelAuthorizer->new(
            permission_engine => GPForum::Test::RealtimePermissionEngine->new,
        ),
        badge_counter => GPForum::Test::RealtimeBadgeCounter->new(
            counts => { 'user-1' => $UNREAD_COUNT },
        ),
        registry => GPForum::Service::Realtime::ConnectionRegistry->new,
    );
    my %socket = (
        'thread:thread-1'      => $thread_connection,
        'notifications:user-1' => $badge_connection,
    );
    for my $channel ( sort keys %socket ) {
        $realtime_hub->register_connection( $channel, { user_id => 'user-1' },
            $socket{$channel} );
        $realtime_hub->subscribe(
            {
                actor         => { user_id => 'user-1' },
                channel       => $channel,
                connection_id => $channel,
            }
        );
    }

    return $realtime_hub;
}

# What the listener delivered to a socket since the last call.
sub _deliver {
    my ($connection) = @_;

    $listener->poll_once;

    return splice @{ $connection->sent };
}

# NOTIFY is asynchronous: it reaches this backend's socket some time after
# the peer commits. Polls until $count items arrive or the attempts run out.
sub _eventually {
    my ( $take, $count ) = @_;

    my @items;
    for ( 1 .. $ATTEMPTS ) {
        push @items, $take->();
        last if @items >= $count;
        sleep $PAUSE_SECONDS;
    }

    return @items;
}

sub _notify_cache {
    my ($request) = @_;

    $peer->do( 'SELECT pg_notify(?, ?)',
        undef, $CACHE_CHANNEL,
        encode_json( { keys => [], tags => [], %{$request} } ) );

    return;
}

sub _notify_event {
    my ($post_id) = @_;

    my $envelope = GPForum::Service::Realtime::EventEnvelope->new;
    my $event    = $envelope->build(
        type           => 'thread.update',
        aggregate_type => 'thread',
        aggregate_id   => 'thread-1',
        payload        => { post_id => $post_id, thread_id => 'thread-1' },
    );
    $peer->do( 'SELECT pg_notify(?, ?)',
        undef, $DOMAIN_CHANNEL, $envelope->serialize($event)->{json} );

    return;
}

sub _done_row {
    my ( $name, $stamp_sql ) = @_;

    $peer->do(
        <<"SQL",
INSERT INTO outbox_messages
    (outbox_id, event_id, queue, job_type, idempotency_key, payload,
     status, next_attempt_at)
VALUES
    (gen_random_uuid(), gen_random_uuid(), 'default', 'domain_event', ?, ?,
     'done', $stamp_sql)
SQL
        undef,
        "realtime-listen-$name",
        encode_json(
            {
                aggregate_id   => "post-$name",
                aggregate_type => 'post',
                domain_payload => { thread_id => 'thread-1' },
                event_id       => "event-$name",
                event_type     => 'post.created',
            }
        ),
    );

    return;
}

# The plan with sequential scans off: which index answers the query, and
# from where, whatever the size of this test database.
sub _plan {
    my ($resultset) = @_;

    my ( $sql, @bind ) = @{ ${ $resultset->as_query } };
    my $dbh = $schema->storage->dbh;
    $dbh->begin_work;
    $dbh->do('SET LOCAL enable_seqscan = off');
    my $plan = $dbh->selectcol_arrayref( "EXPLAIN $sql", undef,
        map { ref $_ eq 'ARRAY' ? $_->[1] : $_ } @bind );
    $dbh->rollback;

    return join "\n", @{$plan};
}

sub _listening {
    my ($connected) = @_;

    return $connected->storage->dbh->selectcol_arrayref(
        'SELECT pg_listening_channels()');
}

sub _backend_pid {
    my ($connected) = @_;

    return $connected->storage->dbh->{pg_pid};
}

1;
