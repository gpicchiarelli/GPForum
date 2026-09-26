# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::PublicCacheAccess;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;
use Mojo::Date;

use GPForum::Web::Access;

our $VERSION = '0.001';

const my $ANY_ETAG => q{*};

has access => sub { return GPForum::Web::Access->new; };

sub is_cacheable ( $self, $controller ) {
    if ( !$self->_cacheable_method($controller) ) {
        return 0;
    }
    if ( $self->access->user_id($controller) ) {
        return 0;
    }

    return 1;
}

sub client_has_fresh_copy ( $self, $controller, $entry ) {
    my $headers = $controller->req->headers;
    if (
        $self->etag_matches(
            $headers->header('If-None-Match'), $entry->{etag}
        )
      )
    {
        return 1;
    }
    if (
        $self->modified_since_matches(
            $headers->header('If-Modified-Since'),
            $entry->{last_modified_epoch}
        )
      )
    {
        return 1;
    }

    return 0;
}

sub etag_matches ( $self, $candidate, $etag ) {
    if ( !$self->access->has_text($candidate) ) {
        return 0;
    }
    if ( !$self->access->has_text($etag) ) {
        return 0;
    }

    return $self->_etag_token_matches( $candidate, $etag );
}

sub modified_since_matches ( $self, $candidate, $last_modified_epoch ) {
    if ( !$self->access->has_text($candidate) ) {
        return 0;
    }
    if ( !defined $last_modified_epoch ) {
        return 0;
    }

    return $self->_epoch_not_after( $candidate, $last_modified_epoch );
}

sub revalidated_state ( $, $cache_state ) {
    if ( $cache_state eq 'hit' ) {
        return 'revalidated';
    }

    return 'miss-revalidated';
}

sub _cacheable_method ( $, $controller ) {
    my $method = $controller->req->method || q{};
    if ( $method eq 'GET' ) {
        return 1;
    }
    if ( $method eq 'HEAD' ) {
        return 1;
    }

    return 0;
}

sub _etag_token_matches ( $, $candidate, $etag ) {
    my %tokens = map { $_ => 1 } split m{\s*,\s*}msx, $candidate;
    if ( $tokens{$ANY_ETAG} ) {
        return 1;
    }
    if ( $tokens{$etag} ) {
        return 1;
    }

    return 0;
}

sub _epoch_not_after ( $, $candidate, $last_modified_epoch ) {
    my $epoch = eval { return Mojo::Date->new($candidate)->epoch; };
    if ( !defined $epoch ) {
        return 0;
    }

    return $epoch >= $last_modified_epoch ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Web::PublicCacheAccess - Public HTTP cache decisions.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $access = GPForum::Web::PublicCacheAccess->new;
    if ( $access->is_cacheable($controller) ) {
        return $cache->render(%input);
    }

=head1 DESCRIPTION

Owns anonymous GET/HEAD cacheability, ETag and Last-Modified freshness, and
revalidation header labels for public SSR. It does not store entries, render
bodies, or talk to PostgreSQL. L<GPForum::Web::PublicHttpCache> keeps those
responsibilities.

=head1 SUBROUTINES/METHODS

=head2 is_cacheable

True for anonymous GET or HEAD requests.

=head2 client_has_fresh_copy

True when If-None-Match or If-Modified-Since matches the cache entry.

=head2 etag_matches

True when the candidate lists the entry ETag or C<*>.

=head2 modified_since_matches

True when If-Modified-Since parses and is not before the entry epoch.

=head2 revalidated_state

Returns C<revalidated> for hits and C<miss-revalidated> for stored misses.

=head1 DIAGNOSTICS

These methods return booleans or header labels. HTTP 304 rendering stays in
L<GPForum::Web::PublicHttpCache>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<GPForum::Web::Access> and L<Mojo::Date>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not decide whether a cache backend is configured; the public HTTP cache
still requires a cache object before consulting this helper.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
