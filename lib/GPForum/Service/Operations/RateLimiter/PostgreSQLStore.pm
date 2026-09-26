# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::RateLimiter::PostgreSQLStore;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base, -signatures;
use POSIX qw(strftime);

use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT          => 60;
const my $DEFAULT_WINDOW_SECONDS => 60;

has clock  => sub { return GPForum::Service::Clock->new; };
has schema => undef;

sub check ( $self, $input ) {
    my $limit          = $input->{limit}          || $DEFAULT_LIMIT;
    my $window_seconds = $input->{window_seconds} || $DEFAULT_WINDOW_SECONDS;
    my $now            = $self->clock->now_epoch;
    my $window_start   = $now - ( $now % $window_seconds );
    my $row            = $self->_upsert_bucket(
        $input,
        {
            actor_hash     => _actor_hash($input),
            limit          => $limit,
            now_epoch      => $now,
            now_iso        => _iso8601_from_epoch($now),
            window_seconds => $window_seconds,
            window_start   => _iso8601_from_epoch($window_start),
            expires_at     =>
              _iso8601_from_epoch( $window_start + $window_seconds ),
        },
    );

    return {
        ok  => $row->{observed_count} <= $limit ? 1 : 0,
        key => join( q{:},
            $input->{scope},  $row->{actor_hash},
            $input->{action}, $row->{window_started_at} ),
        limit           => $limit,
        remaining       => _remaining( $limit, $row->{observed_count} ),
        reset_at_epoch  => $window_start + $window_seconds,
        store           => 'postgresql',
        window_seconds  => $window_seconds,
        observed_count  => $row->{observed_count},
        mitigation_hint => 'slow_down',
        actor_hash      => $row->{actor_hash},
    };
}

sub snapshot ($self) {
    my $count = $self->schema->resultset('RateLimitBucket')->search_rs(
        {
            expires_at => { '>' => $self->clock->now_iso8601 },
        }
    )->count;

    return {
        buckets => $count,
        store   => 'postgresql',
        status  => 'ok',
    };
}

sub _upsert_bucket ( $self, $input, $window ) {
    my $sql = q{
        INSERT INTO rate_limit_buckets (
            scope, actor_hash, action, window_started_at, window_seconds,
            observed_count, blocked_count, first_seen_at, last_seen_at,
            expires_at
        )
        VALUES (?, ?, ?, ?::timestamptz, ?, 1, CASE WHEN 1 > ? THEN 1 ELSE 0 END,
            ?::timestamptz, ?::timestamptz, ?::timestamptz)
        ON CONFLICT (scope, actor_hash, action, window_started_at)
        DO UPDATE SET
            observed_count = rate_limit_buckets.observed_count + 1,
            blocked_count = rate_limit_buckets.blocked_count
                + CASE WHEN rate_limit_buckets.observed_count + 1 > ? THEN 1 ELSE 0 END,
            last_seen_at = EXCLUDED.last_seen_at,
            expires_at = EXCLUDED.expires_at
        RETURNING scope, actor_hash, action, window_started_at,
            observed_count, blocked_count
    };

    return $self->schema->storage->dbh->selectrow_hashref(
        $sql,                      undef,
        $input->{scope},           $window->{actor_hash},
        $input->{action},          $window->{window_start},
        $window->{window_seconds}, $window->{limit},
        $window->{now_iso},        $window->{now_iso},
        $window->{expires_at},     $window->{limit},
    );
}

sub _actor_hash ($input) {
    return sha256_hex( join q{:}, $input->{scope}, $input->{actor_id} || q{} );
}

sub _remaining ( $limit, $count ) {
    my $remaining = $limit - $count;

    return $remaining > 0 ? $remaining : 0;
}

sub _iso8601_from_epoch ($epoch) {
    return strftime '%Y-%m-%dT%H:%M:%SZ', gmtime $epoch;
}

1;
