# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::CacheFactory;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base, -signatures;

use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::SharedCache;
use GPForum::Service::Operations::TieredCache;

our $VERSION = '0.001';

sub build ( $, $config ) {
    my $local  = _local_cache($config);
    my $shared = _shared_cache($config);
    if ($shared) {
        return GPForum::Service::Operations::TieredCache->new(
            l1 => $local,
            l2 => $shared,
        );
    }

    return _without_shared( $config, $local );
}

sub _local_cache ($config) {
    return GPForum::Service::Operations::LocalCache->new(
        max_entries => $config->local_cache_max_entries,
        namespace   => 'gpforum',
    );
}

sub _shared_cache ($config) {
    if ( !_has_text( $config->glifistore_url ) ) {
        my $undefined;
        return $undefined;
    }

    return GPForum::Service::Operations::SharedCache->connect_required(
        {
            namespace   => 'gpforum',
            ttl_seconds => $config->category_cache_ttl_seconds,
            url         => $config->glifistore_url,
        }
    );
}

sub _without_shared ( $config, $local ) {
    if ( $config->requires_glifistore ) {
        croak 'glifistore_url is required';
    }

    return $local;
}

sub _has_text ($value) {
    return defined $value && length $value ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::CacheFactory - Build the process cache stack.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $cache = GPForum::Service::Operations::CacheFactory->build($config);

=head1 DESCRIPTION

Constructs the disposable application cache used by public SSR rendering,
category read models, and worker tag invalidation.

C<LocalCache> is always L1. When C<glifistore_url> is set, L2 is
L<GPForum::Service::Operations::SharedCache> behind
L<GPForum::Service::Operations::TieredCache>. Staging and production
profiles fail closed if the URL is missing. PostgreSQL remains the only
source of truth; GlifiStore is never treated as authoritative.

=head1 SUBROUTINES/METHODS

=head2 build

Returns a local cache, or a tiered L1/L2 cache when GlifiStore is
configured. Croaks when a deployed profile is missing C<glifistore_url>.

=head1 DIAGNOSTICS

Croaks C<glifistore_url is required> when a staging or production profile
has no GlifiStore URL.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<glifistore_url>, C<local_cache_max_entries>, and
C<category_cache_ttl_seconds> from L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<Carp>, L<Mojo::Base>, L<GPForum::Service::Operations::LocalCache>,
L<GPForum::Service::Operations::SharedCache>, and
L<GPForum::Service::Operations::TieredCache>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A reachable GlifiStore is not required at process start: the first call
tries it. After a failed call the shared layer skips GlifiStore for fifteen
seconds (lookups, writes, invalidations and the readiness ping alike), so a
hung server costs each process one timeout rather than every request one.
Meanwhile the cache degrades to L1 and PostgreSQL, and an invalidation
skipped then leaves the L2 entry until its TTL. The ERASE of an absent key is
not a failure, and an overloaded server keeps its connection.

Tag invalidation erases one token per tag; an entry written under an older
token, or before tokens existed, misses. An entry filled from L2 into L1
keeps only the lifetime it had left in L2. The shared client is opened with
C<connect_required>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
