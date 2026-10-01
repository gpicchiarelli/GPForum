# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::PublicHttpCache;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Digest::SHA qw(sha1_hex);
use GPForum::Web::Access;
use GPForum::Web::PublicCacheAccess;
use Mojo::Base -base, -signatures;
use Mojo::Date;
use Mojo::Util qw(encode);

our $VERSION = '0.001';

const my $DEFAULT_TTL_SECONDS => 30;
const my $HTTP_NOT_MODIFIED   => 304;
const my $BODY_ENCODING       => 'UTF-8';

has cache        => undef;
has cache_access => sub { return GPForum::Web::PublicCacheAccess->new; };
has ttl_seconds  => $DEFAULT_TTL_SECONDS;

sub render ( $self, %input ) {
    $self->_validate_render_input( \%input );
    $input{payload} ||= {};
    $input{tags}    ||= [];
    if ( !$self->_is_cacheable( $input{controller} ) ) {
        return $self->_render_uncached( \%input );
    }

    return $self->_render_cached( \%input );
}

# Answers from the cache before the page's queries run; true when answered.
# A miss is marked on the options, which the page passes on to render: that
# render stores without asking L1 and L2 again. Each miss used to look the key
# up twice, and while GlifiStore hangs every ask costs the request a timeout.
# The mark carries the cache's ticket for the page's tags, taken here, before
# the queries: a moderation purge that lands while they run then retires the
# page the render stores, instead of missing it.
sub serve_cached ( $self, $controller, $options ) {
    return 0 if !$options || !$options->{key};
    return 0 if !$self->_is_cacheable($controller);

    my $entry = $self->_current_entry( $options->{key} );
    if ( !$entry ) {
        $options->{known_miss} = 1;
        if ( $self->cache->can('ticket') ) {
            $options->{ticket} = $self->cache->ticket( $options->{tags} );
        }
        return 0;
    }

    $self->_render_entry( $controller, $entry, 'hit' );

    return 1;
}

sub _validate_render_input ( $self, $input ) {
    my %required = (
        controller => 'controller is required',
        key        => 'cache key is required',
        template   => 'template is required',
    );
    for my $field ( sort keys %required ) {
        if ( _is_blank( $input->{$field} ) ) {
            croak $required{$field};
        }
    }
    if ( !defined $input->{status} ) {
        croak 'status is required';
    }

    return;
}

sub _is_blank ($value) {
    return GPForum::Web::Access->new->has_text($value) ? 0 : 1;
}

sub _is_cacheable ( $self, $controller ) {
    if ( !$self->cache ) {
        return 0;
    }

    return $self->cache_access->is_cacheable($controller);
}

sub _render_cached ( $self, $input ) {
    my $entry =
      $input->{known_miss} ? undef : $self->_current_entry( $input->{key} );
    if ($entry) {
        return $self->_render_entry( $input->{controller}, $entry, 'hit' );
    }

    return $self->_store_and_render($input);
}

sub _store_and_render ( $self, $input ) {
    my $entry = $self->_build_entry($input);
    my %put   = (
        tags        => $input->{tags},
        ttl_seconds => $self->ttl_seconds,
    );
    if ( $input->{ticket} ) {
        $put{ticket} = $input->{ticket};
    }
    $self->cache->put( $input->{key}, $entry, \%put );

    return $self->_render_entry( $input->{controller}, $entry, 'miss' );
}

# The page is kept, hashed and sent as UTF-8 bytes. It was kept as the
# characters render_to_string returns: a title with a character past U+00FF
# failed the page with "Wide character", and an accented one reached the
# browser as Latin-1 under a UTF-8 header.
# An entry cached before bodies were bytes holds characters: rebuilt, not
# served.
sub _current_entry ( $self, $key ) {
    my $entry = $self->cache->get($key);
    if ( !$entry || ( $entry->{encoding} // q{} ) ne $BODY_ENCODING ) {
        my $undefined;
        return $undefined;
    }

    return $entry;
}

sub _build_entry ( $self, $input ) {
    my $body = encode(
        $BODY_ENCODING,
        q{}
          . $input->{controller}->render_to_string(
            template => $input->{template},
            %{ $input->{payload} },
          )
    );
    my $epoch = time;

    return {
        body                => $body,
        encoding            => $BODY_ENCODING,
        cache_control       => _cache_control( $self->ttl_seconds ),
        etag                => 'W/"' . sha1_hex($body) . q{"},
        last_modified       => Mojo::Date->new($epoch)->to_string,
        last_modified_epoch => $epoch,
        status              => $input->{status},
    };
}

sub _render_entry ( $self, $controller, $entry, $cache_state ) {
    $self->_set_headers( $controller, $entry, $cache_state );
    if ( $self->cache_access->client_has_fresh_copy( $controller, $entry ) ) {
        $controller->res->headers->header( 'X-GPForum-Cache' =>
              $self->cache_access->revalidated_state($cache_state) );
        return $controller->render(
            data   => q{},
            status => $HTTP_NOT_MODIFIED,
        );
    }

    return $controller->render(
        data   => $entry->{body},
        format => 'html',
        status => $entry->{status},
    );
}

sub _render_uncached ( $self, $input ) {
    return $input->{controller}->render(
        template => $input->{template},
        %{ $input->{payload} },
        status => $input->{status},
    );
}

sub _set_headers ( $, $controller, $entry, $cache_state ) {
    my $headers = $controller->res->headers;
    $headers->header( 'Cache-Control'    => $entry->{cache_control} );
    $headers->header( 'ETag'             => $entry->{etag} );
    $headers->header( 'Last-Modified'    => $entry->{last_modified} );
    $headers->header( 'Vary'             => 'Accept, Accept-Language, Cookie' );
    $headers->header( 'X-GPForum-Cache'  => $cache_state );
    $headers->header( 'X-GPForum-Source' => 'public-http-cache' );

    return;
}

sub _cache_control ($ttl_seconds) {
    return sprintf 'public, max-age=%d, stale-while-revalidate=%d',
      $ttl_seconds, $ttl_seconds;
}

1;

__END__

=head1 NAME

GPForum::Web::PublicHttpCache - Serve anonymous public pages from the application cache, with HTTP validators.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $http_cache = GPForum::Web::PublicHttpCache->new(
        cache       => $c->gp_local_cache,
        ttl_seconds => 60,
    );

    my $options = {
        key  => 'forum-ssr:categories:en:light:/categories:limit=50',
        tags => [ 'forum:public-html', 'forum:categories' ],
    };
    return if $http_cache->serve_cached( $c, $options );

    my $categories = load_categories();    # the page's queries
    return $http_cache->render(
        controller => $c,
        payload    => { categories => $categories },
        status     => 200,
        template   => 'forum/categories',
        %{$options},
    );

=head1 DESCRIPTION

Renders a public HTML page through the application cache (a
L<GPForum::Service::Operations::TieredCache>, or a LocalCache without
GlifiStore), so anonymous visitors share one rendering of it. A cached entry
holds the rendered body, its status and its validators: a weak C<ETag> (the
SHA-1 of the body), C<Last-Modified> (when it was rendered) and
C<Cache-Control: public, max-age=N, stale-while-revalidate=N>. A request
whose C<If-None-Match> or C<If-Modified-Since> matches the entry gets a 304
with an empty body.

Whether a request may use the cache is L<GPForum::Web::PublicCacheAccess>'s
call: only a GET or HEAD from a visitor who is not signed in. Any other
request, and every request when no cache is set, is rendered as usual with
none of the cache headers.

A page asks L</serve_cached> before its queries run, so a hit spares them.
On a miss it hands the same options to L</render>, which then stores the page
without looking the key up again: each miss used to look it up twice, and
while GlifiStore hangs every lookup costs the request a timeout. The miss
also carries the cache's ticket for the page's tags, taken before the
queries, so a moderation purge that lands while they run retires the page
L</render> stores instead of missing it.

A response served through the cache carries C<Cache-Control>, C<ETag>,
C<Last-Modified>, C<Vary: Accept, Accept-Language, Cookie>,
C<X-GPForum-Source: public-http-cache> and C<X-GPForum-Cache>: C<hit> or
C<miss>, or for a 304 C<revalidated> or C<miss-revalidated>.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<cache> is the application cache, with C<get>,
C<put> and optionally C<ticket>; without one nothing is cached.
C<cache_access> defaults to a L<GPForum::Web::PublicCacheAccess>.
C<ttl_seconds> is both the lifetime of a stored entry and the C<max-age>
sent to clients; 30 by default.

=head2 render

Takes a hash: C<controller>, C<key> (the cache key), C<template> and
C<status>, all required; C<payload>, a hash reference of template values
(empty by default), passed to the controller's C<render_to_string> or
C<render> beside C<template>, so a key Mojolicious reads as a render option
(C<text>, C<json>, C<data>, C<layout>, C<format> and the like) acts as one;
C<tags>, an array reference stored with the entry (empty by default); and
C<known_miss> and C<ticket>, as L</serve_cached> leaves them on its
options. When the request is not cacheable, renders the template with
the payload and status and nothing more. Otherwise serves the entry cached
under the key, unless C<known_miss> says there is none. On a miss it renders
the template to a string, stores the entry with the tags, C<ttl_seconds> and
the ticket if there is one, and serves it. Serving sets the headers above and
renders the body as HTML with the entry's status, or an empty 304 when the
client's copy is fresh. Returns what the controller's C<render> returns.

=head2 serve_cached

Takes the controller and the page's cache options (C<key>, C<tags>). Returns
1 after serving the entry cached under C<key>, as L</render> serves it.
Returns 0, having rendered nothing, when the options or their C<key> are
missing, the request is not cacheable, or the key is not cached. A miss sets
C<known_miss> on the options and, when the cache has a C<ticket> method,
C<ticket> to its ticket for the options' C<tags>.

=head1 DIAGNOSTICS

L</render> croaks with C<controller is required>, C<cache key is required> or
C<template is required> when that input is undefined or empty (checked in
that order), and with C<status is required> when no status is given. These
are checked before whether the request is cacheable. Errors from the cache
and from rendering the template propagate, and so does
C<Wide character in subroutine entry> from L<Digest::SHA> when a page
rendered for the cache holds a character above U+00FF (see
L</BUGS AND LIMITATIONS>).

=head1 CONFIGURATION AND ENVIRONMENT

None directly. The C<gp_public_http_cache> helper
(L<GPForum::Bootstrap::Forum>) builds one per call over the
C<gp_local_cache> application cache, with C<category_cache_ttl_seconds> as
C<ttl_seconds>.

=head1 DEPENDENCIES

L<Carp>, L<Const::Fast>, L<Digest::SHA>, L<Mojo::Base>, L<Mojo::Date>,
L<GPForum::Web::Access>, L<GPForum::Web::PublicCacheAccess>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The cache key is the caller's (L<GPForum::Web::ForumAccess> builds it from
the page, locale, theme, path and limit); a variation of the body the key
does not name is served to every visitor. The entry is stored with whatever
status the page renders, and C<Last-Modified> is when the entry was
rendered, not when its content changed.

The body is the character string C<render_to_string> returns, never
encoded to UTF-8: it is hashed and sent as it is. A page holding a
character above U+00FF (an em dash, a curly quote, an emoji in a thread
title) dies in C<sha1_hex> and the visitor gets a 500. A page whose
non-ASCII characters are all Latin-1, such as the Italian categories page
with its C<IdentitE<agrave>> label, is sent as Latin-1 bytes under
C<text/html;charset=UTF-8>, which is not valid UTF-8, so the browser shows
replacement characters. A signed-in visitor's page, which is not cached, is
encoded as usual.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
