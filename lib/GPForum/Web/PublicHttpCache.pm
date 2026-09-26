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

our $VERSION = '0.001';

const my $DEFAULT_TTL_SECONDS => 30;
const my $HTTP_NOT_MODIFIED   => 304;

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
sub serve_cached ( $self, $controller, $options ) {
    return 0 if !$options || !$options->{key};
    return 0 if !$self->_is_cacheable($controller);

    my $entry = $self->cache->get( $options->{key} );
    if ( !$entry ) {
        $options->{known_miss} = 1;
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
      $input->{known_miss} ? undef : $self->cache->get( $input->{key} );
    if ($entry) {
        return $self->_render_entry( $input->{controller}, $entry, 'hit' );
    }

    return $self->_store_and_render($input);
}

sub _store_and_render ( $self, $input ) {
    my $entry = $self->_build_entry($input);
    $self->cache->put(
        $input->{key},
        $entry,
        {
            tags        => $input->{tags},
            ttl_seconds => $self->ttl_seconds,
        }
    );

    return $self->_render_entry( $input->{controller}, $entry, 'miss' );
}

sub _build_entry ( $self, $input ) {
    my $body = q{}
      . $input->{controller}->render_to_string(
        template => $input->{template},
        %{ $input->{payload} },
      );
    my $epoch = time;

    return {
        body                => $body,
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
