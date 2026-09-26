# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::TieredCache;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

has bus   => undef;
has l1    => undef;
has l2    => undef;
has stats => sub {
    return {
        hits                 => 0,
        invalidations        => 0,
        l2_fills             => 0,
        misses               => 0,
        remote_invalidations => 0,
        writes               => 0,
    };
};

sub get ( $self, $key ) {
    $self->_require_layers;

    # L1 is process-local and this read short-circuits on it, so a sibling
    # worker's invalidation has to be absorbed before the hit is trusted.
    # Otherwise every Hypnotoad worker keeps serving content that was hidden,
    # edited or deleted until the entry expires.
    $self->absorb_remote_invalidations;
    my $local = $self->l1->get($key);
    if ( defined $local ) {
        $self->stats->{hits} += 1;
        return $local;
    }

    return $self->_fill_from_shared($key);
}

sub put ( $self, $key, $value, $options ) {
    $self->_require_layers;
    $self->l1->put( $key, $value, $options );
    $self->l2->put( $key, $value, $options );
    $self->stats->{writes} += 1;
    return $value;
}

sub get_or_set ( $self, $key, $producer, $options = undef ) {
    my $cached = $self->get($key);
    if ( defined $cached ) {
        return $cached;
    }

    my $generated = $producer->();
    $self->put( $key, $generated, $options );
    return $generated;
}

sub invalidate ( $self, $key ) {
    $self->_require_layers;
    my $removed = $self->l1->invalidate($key);
    $self->l2->invalidate($key);
    $self->stats->{invalidations} += $removed;
    $self->_publish( { keys => [$key] } );
    return $removed;
}

sub invalidate_tag ( $self, $tag ) {
    $self->_require_layers;
    my $removed = $self->l1->invalidate_tag($tag);
    $self->l2->invalidate_tag($tag);
    $self->stats->{invalidations} += $removed;
    $self->_publish( { tags => [$tag] } );
    return $removed;
}

# Applies what sibling workers invalidated. Only L1 is touched: whoever
# published already invalidated the shared layer, and re-invalidating it would
# turn one write into one per worker.
sub absorb_remote_invalidations ($self) {
    my $bus = $self->bus;
    if ( !$bus ) {
        return 0;
    }

    my $removed = 0;
    for my $request ( @{ $bus->drain } ) {
        $removed += $self->_apply_remote($request);
    }
    $self->stats->{remote_invalidations} += $removed;

    return $removed;
}

sub _apply_remote ( $self, $request ) {
    if ( $request->{clear} ) {
        return $self->l1->clear;
    }

    my $removed = 0;
    for my $key ( @{ $request->{keys} || [] } ) {
        $removed += $self->l1->invalidate($key);
    }
    for my $tag ( @{ $request->{tags} || [] } ) {
        $removed += $self->l1->invalidate_tag($tag);
    }

    return $removed;
}

sub _publish ( $self, $request ) {
    my $bus = $self->bus;
    if ( !$bus ) {
        return 0;
    }

    return $bus->publish($request);
}

sub purge_expired ($self) {
    $self->_require_layers;
    my $removed = $self->l1->purge_expired;
    $self->l2->purge_expired;
    return $removed;
}

sub clear ($self) {
    $self->_require_layers;
    my $removed = $self->l1->clear;
    $self->l2->clear;
    $self->stats->{invalidations} += $removed;
    $self->_publish( { clear => 1 } );
    return $removed;
}

sub snapshot ($self) {
    $self->_require_layers;
    return {
        layer     => 'tiered',
        namespace => $self->l1->snapshot->{namespace},
        l1        => $self->l1->snapshot,
        l2        => $self->l2->snapshot,
        bus       => $self->bus ? $self->bus->snapshot : undef,
        stats     => { %{ $self->stats } },
    };
}

sub ping ($self) {
    $self->_require_layers;
    return $self->l2->ping;
}

sub _fill_from_shared ( $self, $key ) {
    my $payload = $self->l2->lookup($key);
    my $fill    = $payload ? $self->_fill_options($payload) : undef;
    if ( !$fill ) {
        $self->stats->{misses} += 1;
        my $undefined;
        return $undefined;
    }

    $self->l1->put( $key, $payload->{value}, $fill );
    $self->stats->{l2_fills} += 1;
    $self->stats->{hits}     += 1;
    return $payload->{value};
}

# A filled entry lives in L1 no longer than it has left in L2. The fill used
# to take L1's default TTL, so an entry with a second left in L2 lived another
# minute in every process, and a missed invalidation was no longer bounded by
# one TTL, the recovery ADR 0067 counts on. A layer that reports no lifetime
# (LocalCache as L2) keeps the default. Nothing when the entry has run out.
sub _fill_options ( $self, $payload ) {
    my $options = { tags => $payload->{tags} || [] };
    my $expires = $payload->{expires_at_epoch};
    if ( !defined $expires ) {
        return $options;
    }

    my $remaining = $expires - $self->l1->clock->now_epoch;
    if ( $remaining <= 0 ) {
        my $undefined;
        return $undefined;
    }

    $options->{ttl_seconds} = $remaining;
    return $options;
}

sub _require_layers ($self) {
    if ( !$self->l1 || !$self->l2 ) {
        croak 'tiered cache requires l1 and l2 layers';
    }

    return;
}

1;
