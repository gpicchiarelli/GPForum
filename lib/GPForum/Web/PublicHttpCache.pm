package GPForum::Web::PublicHttpCache;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Digest::SHA qw(sha1_hex);
use Mojo::Base -base;
use Mojo::Date;

our $VERSION = '0.001';

const my $DEFAULT_TTL_SECONDS => 30;
const my $HTTP_NOT_MODIFIED   => 304;
const my $ANY_ETAG            => q{*};

has cache       => undef;
has ttl_seconds => $DEFAULT_TTL_SECONDS;

sub render {
    my ( $self, %input ) = @_;

    $self->_validate_render_input( \%input );
    $input{payload} ||= {};
    $input{tags}    ||= [];

    return $self->_render_uncached( \%input )
      if !$self->_is_cacheable( $input{controller} );

    my $entry = $self->cache->get( $input{key} );
    if ($entry) {
        return $self->_render_entry( $input{controller}, $entry, 'hit' );
    }

    $entry = $self->_build_entry( \%input );
    $self->cache->put(
        $input{key},
        $entry,
        {
            tags        => $input{tags},
            ttl_seconds => $self->ttl_seconds,
        }
    );

    return $self->_render_entry( $input{controller}, $entry, 'miss' );
}

sub _validate_render_input {
    my ( $self, $input ) = @_;

    my %required = (
        controller => 'controller is required',
        key        => 'cache key is required',
        template   => 'template is required',
    );
    for my $field ( sort keys %required ) {
        croak $required{$field} if _is_blank( $input->{$field} );
    }

    croak 'status is required' if !defined $input->{status};

    return;
}

sub _is_blank {
    my ($value) = @_;

    return 1 if !defined $value;
    return length $value ? 0 : 1;
}

sub _is_cacheable {
    my ( $self, $controller ) = @_;

    return 0 if !$self->cache;

    my %cacheable_method = map { $_ => 1 } qw(GET HEAD);
    my $method           = $controller->req->method || q{};
    return 0 if !$cacheable_method{$method};

    return 0 if $controller->session('user_id');

    return 1;
}

sub _build_entry {
    my ( $self, $input ) = @_;

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

sub _render_entry {
    my ( $self, $controller, $entry, $cache_state ) = @_;

    $self->_set_headers( $controller, $entry, $cache_state );

    if ( $self->_client_has_fresh_copy( $controller, $entry ) ) {
        $controller->res->headers->header(
              'X-GPForum-Cache' => $cache_state eq 'hit'
            ? 'revalidated'
            : 'miss-revalidated'
        );
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

sub _render_uncached {
    my ( $self, $input ) = @_;

    return $input->{controller}->render(
        template => $input->{template},
        %{ $input->{payload} },
        status => $input->{status},
    );
}

sub _set_headers {
    my ( $self, $controller, $entry, $cache_state ) = @_;

    my $headers = $controller->res->headers;
    $headers->header( 'Cache-Control'    => $entry->{cache_control} );
    $headers->header( 'ETag'             => $entry->{etag} );
    $headers->header( 'Last-Modified'    => $entry->{last_modified} );
    $headers->header( 'Vary'             => 'Accept, Cookie' );
    $headers->header( 'X-GPForum-Cache'  => $cache_state );
    $headers->header( 'X-GPForum-Source' => 'public-http-cache' );

    return;
}

sub _client_has_fresh_copy {
    my ( $self, $controller, $entry ) = @_;

    my $headers = $controller->req->headers;
    return 1
      if _etag_matches( $headers->header('If-None-Match'), $entry->{etag} );
    return 1
      if _modified_since_matches( $headers->header('If-Modified-Since'),
        $entry->{last_modified_epoch} );

    return 0;
}

sub _etag_matches {
    my ( $candidate, $etag ) = @_;

    return 0 if !defined $candidate || !defined $etag;

    my %tokens = map { $_ => 1 } split m{\s*,\s*}msx, $candidate;
    return 1 if $tokens{$ANY_ETAG};
    return 1 if $tokens{$etag};

    return 0;
}

sub _modified_since_matches {
    my ( $candidate, $last_modified_epoch ) = @_;

    return 0 if !defined $candidate || !defined $last_modified_epoch;

    my $epoch = eval { Mojo::Date->new($candidate)->epoch };
    return 0 if !defined $epoch;

    return $epoch >= $last_modified_epoch ? 1 : 0;
}

sub _cache_control {
    my ($ttl_seconds) = @_;

    return sprintf 'public, max-age=%d, stale-while-revalidate=%d',
      $ttl_seconds, $ttl_seconds;
}

1;
