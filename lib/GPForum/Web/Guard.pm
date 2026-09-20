package GPForum::Web::Guard;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Web::ErrorPayload;
use GPForum::Web::Responder;

our $VERSION = '0.001';

const my $HTTP_BAD_REQUEST         => 400;
const my $HTTP_UNAUTHORIZED        => 401;
const my $HTTP_FORBIDDEN           => 403;
const my $HTTP_NOT_FOUND           => 404;
const my $HTTP_CONFLICT            => 409;
const my $HTTP_TOO_MANY            => 429;
const my $HTTP_SERVER_ERROR        => 500;
const my $HTTP_SERVICE_UNAVAILABLE => 503;

sub csrf_failure {
    my ( $self, $controller ) = @_;

    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->csrf_failure,
            status  => $HTTP_FORBIDDEN,
        }
    );
}

sub unauthorized {
    my ( $self, $controller ) = @_;

    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->unauthorized,
            status  => $HTTP_UNAUTHORIZED,
        }
    );
}

sub forbidden {
    my ( $self, $controller, $input ) = @_;

    return $self->_error(
        $controller,
        {
            payload =>
              GPForum::Web::ErrorPayload->forbidden( %{ $input || {} } ),
            status => $HTTP_FORBIDDEN,
        }
    );
}

sub bad_request {
    my ( $self, $controller, $input ) = @_;

    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->bad_request( %{$input} ),
            status  => $HTTP_BAD_REQUEST,
        }
    );
}

sub not_found {
    my ( $self, $controller, $error ) = @_;

    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->not_found( error => $error ),
            status  => $HTTP_NOT_FOUND,
        }
    );
}

sub conflict {
    my ( $self, $controller, $input ) = @_;

    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->conflict( %{$input} ),
            status  => $HTTP_CONFLICT,
        }
    );
}

sub rate_limited {
    my ( $self, $controller, $input ) = @_;

    return $self->_error(
        $controller,
        {
            payload =>
              GPForum::Web::ErrorPayload->rate_limited( %{ $input || {} } ),
            status => $HTTP_TOO_MANY,
        }
    );
}

sub system_failure {
    my ( $self, $controller ) = @_;

    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->system_failure,
            status  => $HTTP_SERVER_ERROR,
        }
    );
}

sub service_unavailable {
    my ( $self, $controller ) = @_;

    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->unavailable,
            status  => $HTTP_SERVICE_UNAVAILABLE,
        }
    );
}

sub _error {
    my ( undef, $controller, $input ) = @_;

    return GPForum::Web::Responder->new->error(
        {
            controller => $controller,
            payload    => $input->{payload},
            status     => $input->{status},
        }
    );
}

1;

__END__

=head1 NAME

GPForum::Web::Guard - Shared CSRF, auth, and HTTP error rendering.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    return GPForum::Web::Guard->new->unauthorized($controller);

=head1 DESCRIPTION

Renders the existing C<ErrorPayload> contracts through C<Responder>. Controllers
keep CSRF and permission decisions; this object only maps those decisions to
HTTP responses. It does not talk to stores or DBIx::Class.

=head1 SUBROUTINES/METHODS

=head2 csrf_failure

Renders a forbidden CSRF failure.

=head2 unauthorized

Renders an authentication-required error.

=head2 forbidden

Renders a permission-denied error. An optional payload hash may override the
error message.

=head2 rate_limited

Renders a too-many-requests error. An optional payload hash may override the
message.

=head2 bad_request

Renders a validation error from a payload hash.

=head2 not_found

Renders a missing-resource error.

=head2 conflict

Renders a blocked or conflicting write.

=head2 system_failure

Renders an internal error.

=head2 service_unavailable

Renders a generic service-unavailable error for store or database failures.
The payload does not include the underlying exception.

=head1 DIAGNOSTICS

JSON versus HTML negotiation stays inside L<GPForum::Web::Responder>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<GPForum::Web::ErrorPayload> and L<GPForum::Web::Responder>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Security telemetry remains optional in the calling controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
