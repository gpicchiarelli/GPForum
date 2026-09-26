# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::Guard;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

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

sub csrf_failure ( $self, $controller ) {
    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->csrf_failure,
            status  => $HTTP_FORBIDDEN,
        }
    );
}

sub unauthorized ( $self, $controller ) {
    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->unauthorized,
            status  => $HTTP_UNAUTHORIZED,
        }
    );
}

# ADR 0110's explain, for operators: a refused permission is logged with the
# permission checked, for whom and the binding that would have granted it,
# so "why is this moderator refused on that category" is answered from the
# log, next to the user's bindings on /admin/users/:user_id/roles, rather
# than by reading SQL. The wording follows PermissionGate: a check without a
# scope is met only by a global binding; one with a scope, by a global
# binding or one on exactly that resource and space.
sub log_denial ( $self, $controller, $user_id, $permission ) {
    my $resource = _scope( $permission->{resource_id} );
    my $space    = _scope( $permission->{space_id} );
    my $needs =
      !defined $resource && !defined $space
      ? 'a global binding'
      : sprintf 'a global binding, or one on resource %s in space %s',
      $resource // 'none', $space // 'none';

    $controller->app->log->info(
        sprintf 'permission denied: user %s lacks %s.%s (needs %s) on %s',
        $user_id                     // q{-},
        $permission->{resource_type} // q{-},
        $permission->{action}        // q{-},
        $needs,
        $controller->req->url->path,
    );

    return;
}

sub _scope ($value) {
    my $undefined;
    return defined $value && length $value ? $value : $undefined;
}

sub forbidden ( $self, $controller, $input = undef ) {
    return $self->_error(
        $controller,
        {
            payload =>
              GPForum::Web::ErrorPayload->forbidden( %{ $input || {} } ),
            status => $HTTP_FORBIDDEN,
        }
    );
}

sub bad_request ( $self, $controller, $input ) {
    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->bad_request( %{$input} ),
            status  => $HTTP_BAD_REQUEST,
        }
    );
}

sub not_found ( $self, $controller, $error ) {
    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->not_found( error => $error ),
            status  => $HTTP_NOT_FOUND,
        }
    );
}

sub conflict ( $self, $controller, $input ) {
    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->conflict( %{$input} ),
            status  => $HTTP_CONFLICT,
        }
    );
}

sub rate_limited ( $self, $controller, $input = undef ) {
    return $self->_error(
        $controller,
        {
            payload =>
              GPForum::Web::ErrorPayload->rate_limited( %{ $input || {} } ),
            status => $HTTP_TOO_MANY,
        }
    );
}

sub system_failure ( $self, $controller ) {
    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->system_failure,
            status  => $HTTP_SERVER_ERROR,
        }
    );
}

sub service_unavailable ( $self, $controller ) {
    return $self->_error(
        $controller,
        {
            payload => GPForum::Web::ErrorPayload->unavailable,
            status  => $HTTP_SERVICE_UNAVAILABLE,
        }
    );
}

sub _error ( $, $controller, $input ) {
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

=head2 log_denial

Logs, at info, the permission a user was refused and its scope.

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
