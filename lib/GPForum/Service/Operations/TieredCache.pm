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

    my %put    = %{ $options || {} };
    my $ticket = $self->ticket( $put{tags}, { mint => 1 } );
    if ($ticket) {
        $put{ticket} = $ticket;
    }
    my $generated = $producer->();
    $self->put( $key, $generated, \%put );
    return $generated;
}

# L2's tokens for the tags, taken before a value is computed and passed to put
# as its ticket (SharedCache::ticket). L1 takes none: another process's purge
# reaches it on the bus at the next get, which drops the entry if it is
# already written. Nothing when L2 keeps no tokens.
sub ticket ( $self, $tags, $options = undef ) {
    $self->_require_layers;
    if ( !$self->l2->can('ticket') ) {
        my $undefined;
        return $undefined;
    }

    return $self->l2->ticket( $tags, $options );
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

__END__

=head1 NAME

GPForum::Service::Operations::TieredCache - A process-local L1 in front of a shared L2, kept coherent across workers.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $cache = GPForum::Service::Operations::TieredCache->new(
        l1 => GPForum::Service::Operations::LocalCache->new,
        l2 => $shared_cache,
    );
    $cache->bus($invalidation_bus);

    my $categories = $cache->get_or_set(
        'categories:list:anonymous:50',
        sub { return load_categories() },
        { tags => ['forum:categories'], ttl_seconds => 60 },
    );
    $cache->invalidate_tag('forum:categories');

=head1 DESCRIPTION

The application cache L<GPForum::Service::Operations::CacheFactory> builds
when GlifiStore is configured. L1 is a
L<GPForum::Service::Operations::LocalCache> private to the process; L2 is a
L<GPForum::Service::Operations::SharedCache> every process shares. A read
tries L1 first and falls back to L2, copying an L2 hit into L1; a write and
an invalidation go to both layers. PostgreSQL stays the source of truth:
either layer may lose an entry at any time.

L1 belongs to one process, so an invalidation raised in one Hypnotoad worker
would leave the others serving the old entry, a hidden or deleted post among
them, until it expired. With a
L<GPForum::Service::Operations::CacheInvalidationBus> attached as C<bus>,
every invalidation and clear is published on it, and every L</get> first
applies what the other workers published. It applies it to L1 only: the
publisher already invalidated L2, and invalidating it again would turn one
write into one per worker.

An entry copied from L2 into L1 keeps only the lifetime it has left in L2,
so a missed invalidation stays bounded by one TTL, the recovery ADR 0067
counts on. L</get_or_set> takes L2's tag tokens (L</ticket>) before it
computes the value, so a purge that lands while the value is computed
retires it instead of being missed.

L1 is used through C<get>, C<put>, C<invalidate>, C<invalidate_tag>,
C<purge_expired>, C<clear>, C<snapshot> and C<clock>; L2 through C<lookup>,
C<put>, C<invalidate>, C<invalidate_tag>, C<purge_expired>, C<clear>,
C<snapshot>, C<ping> and, when it has one, C<ticket>. A LocalCache can serve
as L2: its entries report no expiry, so a copy into L1 takes L1's default
TTL.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<l1> and C<l2> are the two layers; they are not
checked here but every method except L</absorb_remote_invalidations>
requires both. C<bus> is optional: an invalidation bus with C<publish>,
C<drain> and C<snapshot>. C<stats> is a hash reference of counters
(C<hits>, C<misses>, C<l2_fills>, C<writes>, C<invalidations>,
C<remote_invalidations>), all starting at zero.

=head2 get

Takes a key. First applies the bus's pending invalidations
(L</absorb_remote_invalidations>), then returns L1's value when it holds a
defined one. Otherwise looks the key up in L2: a live entry is copied into
L1 with its tags and the seconds it has left in L2 (L1's default TTL when L2
reports no expiry), counted as a hit and an L2 fill, and its value is
returned. Returns C<undef> on a miss, which includes an L2 entry with no
time left by L1's clock; that entry is not copied.

=head2 put

Takes a key, a value and an options hash reference, which must be passed
but may be C<undef>: C<tags>, C<ttl_seconds> and C<ticket>, handed unchanged
to both layers. Counts a write and returns the value, also when L2 failed
to store it. Publishes nothing on the bus.

=head2 get_or_set

Takes a key, a code reference and the optional options of L</put>. Returns
the cached value on a hit (L</get>). On a miss takes a ticket for the
options' C<tags> with C<mint> set (L</ticket>), calls the code reference with
no arguments, stores its result with L</put> under that ticket when there is
one, and returns it.

=head2 ticket

Takes an array reference of tags and an optional options hash reference
(C<mint>), and returns L2's C<ticket> for them, to be passed to L</put> as
its C<ticket> option once the value is computed. With SharedCache that is
C<< { tokens => {...} } >>, or C<< { failed => 1 } >> when GlifiStore could
not read or mint a token. Returns C<undef> when L2 has no C<ticket>
method. L1 takes no ticket: a purge from another process reaches it on the
bus at the next L</get>, which drops the entry if it is already written.

=head2 invalidate

Takes a key. Removes it from L1 and L2 and publishes C<< { keys => [$key] } >>
on the bus. Returns what L1 removed (1 or 0), which is added to
C<invalidations>.

=head2 invalidate_tag

Takes a tag. Invalidates it in L1 and L2 and publishes
C<< { tags => [$tag] } >> on the bus. Returns the number of L1 entries
removed, which is added to C<invalidations>.

=head2 absorb_remote_invalidations

Drains the bus and applies each request to L1 only: a C<clear> request
empties L1; otherwise each of the request's C<keys> and C<tags> is
invalidated. Returns the number of L1 entries removed, which is added to
C<remote_invalidations>, or 0 when there is no bus. L</get> calls it on
every read.

=head2 purge_expired

Calls C<purge_expired> on both layers and returns how many entries L1
removed. With SharedCache as L2 only L1 is purged: SharedCache's
C<purge_expired> does nothing, and GlifiStore drops an entry at its expiry
itself.

=head2 clear

Empties L1, calls L2's C<clear> and publishes C<< { clear => 1 } >>, so the
other workers empty their L1 too. Returns the number of L1 entries removed,
which is added to C<invalidations>.

=head2 snapshot

Returns a hash reference with C<layer> (C<tiered>), C<namespace> (L1's),
C<l1> and C<l2> (each layer's snapshot), C<bus> (the bus's snapshot, or
C<undef> without a bus) and a copy of C<stats>.

=head2 ping

Returns L2's C<ping>. With SharedCache that is 1 when GlifiStore answers,
and 0 when it does not or is being skipped after a failed call.

=head1 DIAGNOSTICS

Every method except L</absorb_remote_invalidations> croaks with
C<tiered cache requires l1 and l2 layers> when either layer is missing.
Errors raised by a layer propagate: LocalCache croaks with
C<cache key is required> for an undefined or empty key in C<get> and C<put>,
and SharedCache does in C<invalidate>. L</ping> dies when L2 has no C<ping>
method, which LocalCache lacks. An error from the code reference given to
L</get_or_set> propagates and nothing is stored. A GlifiStore failure does
not throw: SharedCache turns it into a miss, a write not made or an
invalidation skipped.

=head1 CONFIGURATION AND ENVIRONMENT

None directly. L<GPForum::Service::Operations::CacheFactory> builds it when
C<glifistore_url> is set, and L<GPForum::Bootstrap::Operations> attaches the
bus when the application has a database schema.

=head1 DEPENDENCIES

L<Carp>, L<Mojo::Base>. It works with
L<GPForum::Service::Operations::LocalCache>,
L<GPForum::Service::Operations::SharedCache> and
L<GPForum::Service::Operations::CacheInvalidationBus>, which it does not
load.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Only invalidations and clears travel on the bus. A L</put> that replaces a
key leaves other processes' L1 copy of it in place until it expires or is
invalidated. Without a bus, an invalidation reaches no other process's L1
at all. The bus delivers nothing while the process's database transaction
is open, so a L</get> made inside one can still return an entry another
worker invalidated.

With SharedCache as L2, L</clear> and L</purge_expired> touch L1 only:
SharedCache's C<clear> and C<purge_expired> do nothing. GlifiStore entries
live until their TTL or a key or tag invalidation, and the next L</get>
copies them back into L1.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
