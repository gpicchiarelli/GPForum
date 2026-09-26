# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::RateLimiter::LocalMemoryStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT          => 60;
const my $DEFAULT_WINDOW_SECONDS => 60;

has buckets => sub { return {}; };
has clock   => sub { return GPForum::Service::Clock->new; };

sub check ( $self, $input ) {
    my $key            = _key($input);
    my $limit          = $input->{limit}          || $DEFAULT_LIMIT;
    my $window_seconds = $input->{window_seconds} || $DEFAULT_WINDOW_SECONDS;
    my $now            = $self->clock->now_epoch;
    my $bucket         = $self->_bucket( $key, $now, $window_seconds );

    $bucket->{count} += 1;

    return {
        ok              => $bucket->{count} <= $limit ? 1 : 0,
        key             => $key,
        limit           => $limit,
        remaining       => _remaining( $limit, $bucket->{count} ),
        reset_at_epoch  => $bucket->{reset_at_epoch},
        store           => 'local_memory',
        window_seconds  => $window_seconds,
        observed_count  => $bucket->{count},
        mitigation_hint => 'slow_down',
    };
}

sub snapshot ($self) {
    return {
        buckets => scalar keys %{ $self->buckets },
        store   => 'local_memory',
        status  => 'ok',
    };
}

sub _bucket ( $self, $key, $now, $window_seconds ) {
    my $bucket = $self->buckets->{$key};
    if ( !$bucket || $now >= $bucket->{reset_at_epoch} ) {
        $bucket = {
            count          => 0,
            reset_at_epoch => $now + $window_seconds,
        };
        $self->buckets->{$key} = $bucket;
    }

    return $bucket;
}

sub _key ($input) {
    return join q{:}, $input->{scope}, $input->{actor_id}, $input->{action};
}

sub _remaining ( $limit, $count ) {
    my $remaining = $limit - $count;

    return $remaining > 0 ? $remaining : 0;
}

1;
