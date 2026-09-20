package main;

use strict;
use warnings;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Service::Identity::SessionStore;
use GPForum::Service::Identity::Store;
use GPForum::Service::Identity::Support;
use GPForum::Test::CountingSupport;
use GPForum::Test::FixedClock;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $DEFAULT_INTERVAL => 300;
const my $CUSTOM_INTERVAL  => 900;
const my $NOW              => '2026-05-23T12:00:00Z';
const my $NOW_EPOCH        => 1_779_537_600;
const my $FRESH_SEEN       => '2026-05-23T11:58:00Z';
const my $FRESH_SEEN_PG    => '2026-05-23 13:58:00.25+02';
const my $STALE_SEEN       => '2026-05-23T11:50:00Z';
const my $STALE_SEEN_PG    => '2026-05-23 11:55:00+00';
const my $FUTURE_EXPIRY    => '2026-06-23T12:00:00Z';

_config_contract();
_timestamp_parsing();
_fresh_session_is_not_written();
_stale_session_is_written();
_pg_formatted_timestamps();
_revoked_and_expired_still_checked();
_interval_is_configurable();

done_testing();

sub _config_contract {
    is( GPForum::Config->new->session_touch_interval_seconds,
        $DEFAULT_INTERVAL, 'session touch interval defaults to 300 seconds' );
    is(
        GPForum::Config->from_environment(
            { GPFORUM_SESSION_TOUCH_INTERVAL_SECONDS => $CUSTOM_INTERVAL }
        )->session_touch_interval_seconds,
        $CUSTOM_INTERVAL,
        'session touch interval reads GPFORUM_SESSION_TOUCH_INTERVAL_SECONDS'
    );
    throws_ok {
        GPForum::Config->from_environment(
            { GPFORUM_SESSION_TOUCH_INTERVAL_SECONDS => '0' } );
    }
    qr/session_touch_interval_seconds [ ] must [ ] be/msx,
      'session touch interval must be positive';
    throws_ok {
        GPForum::Config->from_environment(
            { GPFORUM_SESSION_TOUCH_INTERVAL_SECONDS => 'soon' } );
    }
    qr/GPFORUM_SESSION_TOUCH_INTERVAL_SECONDS [ ] must [ ] be/msx,
      'session touch interval must be an integer';

    return;
}

sub _timestamp_parsing {
    my $support = GPForum::Service::Identity::Support->new;

    is( $support->epoch_from_timestamp($NOW),
        $NOW_EPOCH, 'ISO-8601 UTC timestamps parse' );
    is( $support->epoch_from_timestamp('2026-05-23 14:00:00.123+02'),
        $NOW_EPOCH, 'PostgreSQL timestamptz text with offset parses' );
    is( $support->epoch_from_timestamp('2026-05-23 06:30:00-05:30'),
        $NOW_EPOCH, 'negative offsets with minutes parse' );
    ok( !defined $support->epoch_from_timestamp('yesterday'),
        'garbage timestamps are rejected' );
    ok( !defined $support->epoch_from_timestamp(undef),
        'missing timestamps are rejected' );

    return;
}

sub _fresh_session_is_not_written {
    my ( $store, $support ) = _session_store( { last_seen_at => $FRESH_SEEN } );

    my $result = _validate($store);
    ok( $result->{ok}, 'fresh session validates' );
    is( $support->updates, 0, 'fresh session does not issue an UPDATE' );
    is( $store->schema->sessions->[0]{last_seen_at},
        $FRESH_SEEN, 'fresh session keeps last_seen_at' );

    return;
}

sub _stale_session_is_written {
    my ( $store, $support ) = _session_store( { last_seen_at => $STALE_SEEN } );

    my $result = _validate($store);
    ok( $result->{ok}, 'stale session validates' );
    is( $support->updates, 1, 'stale session issues one UPDATE' );
    is( $store->schema->sessions->[0]{last_seen_at},
        $NOW, 'stale session refreshes last_seen_at' );

    _validate($store);
    is( $support->updates, 1,
        'a refreshed session is not written again inside the interval' );

    return;
}

sub _pg_formatted_timestamps {
    my ( $fresh_store, $fresh_support ) =
      _session_store( { last_seen_at => $FRESH_SEEN_PG } );
    _validate($fresh_store);
    is( $fresh_support->updates, 0,
        'fresh PostgreSQL-formatted last_seen_at is not written' );

    my ( $stale_store, $stale_support ) =
      _session_store( { last_seen_at => $STALE_SEEN_PG } );
    _validate($stale_store);
    is( $stale_support->updates, 1,
        'stale PostgreSQL-formatted last_seen_at is written' );

    my ( $broken_store, $broken_support ) =
      _session_store( { last_seen_at => 'not-a-timestamp' } );
    _validate($broken_store);
    is( $broken_support->updates, 1,
        'unparseable last_seen_at is refreshed conservatively' );

    return;
}

sub _revoked_and_expired_still_checked {
    my ( $revoked_store, $revoked_support ) = _session_store(
        {
            last_seen_at => $FRESH_SEEN,
            revoked_at   => '2026-05-23T11:00:00Z',
        }
    );
    my $revoked = _validate($revoked_store);
    is( $revoked->{error}, 'revoked', 'fresh but revoked session is rejected' );
    is( $revoked_support->updates, 0, 'revoked session check is read-only' );

    my ( $expired_store, $expired_support ) = _session_store(
        {
            expires_at   => '2026-05-23T11:59:59Z',
            last_seen_at => $FRESH_SEEN,
        }
    );
    my $expired = _validate($expired_store);
    is( $expired->{error}, 'expired', 'fresh but expired session is rejected' );
    is( $expired_support->updates, 1,
        'expired session is revoked server-side once' );

    return;
}

sub _interval_is_configurable {
    my $support = GPForum::Test::CountingSupport->new;
    my $schema  = GPForum::Test::Schema->new( sessions => [ _row( {} ) ] );
    my $store   = GPForum::Service::Identity::Store->new(
        clock                          => GPForum::Test::FixedClock->new,
        schema                         => $schema,
        session_touch_interval_seconds => $CUSTOM_INTERVAL,
        support                        => $support,
    );
    $schema->sessions->[0]{last_seen_at} = $STALE_SEEN;

    ok(
        $store->validate_session( { session_id => 's-1', user_id => 'u-1' } )
          ->{ok},
        'identity store validates through the session store'
    );
    is( $store->session_store->session_touch_interval_seconds,
        $CUSTOM_INTERVAL, 'identity store forwards the configured interval' );
    is( $support->updates, 0,
        'ten-minute-old session is fresh under a fifteen-minute interval' );

    return;
}

sub _session_store {
    my ($overrides) = @_;

    my $support = GPForum::Test::CountingSupport->new;
    my $store   = GPForum::Service::Identity::SessionStore->new(
        clock  => GPForum::Test::FixedClock->new,
        schema =>
          GPForum::Test::Schema->new( sessions => [ _row($overrides) ] ),
        support => $support,
    );

    return ( $store, $support );
}

sub _row {
    my ($overrides) = @_;

    return {
        expires_at   => $FUTURE_EXPIRY,
        last_seen_at => $FRESH_SEEN,
        revoked_at   => undef,
        session_id   => 's-1',
        user_id      => 'u-1',
        %{$overrides},
    };
}

sub _validate {
    my ($store) = @_;

    return $store->validate_session(
        { session_id => 's-1', user_id => 'u-1' } );
}

1;
