package GPForum::Web::IdentityAccess;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Web::Access;
use GPForum::Web::ErrorPayload;

our $VERSION = '0.001';

const my $HTTP_BAD_REQUEST          => 400;
const my $HTTP_FORBIDDEN            => 403;
const my $HTTP_SERVER_ERROR         => 500;
const my $HTTP_SERVICE_UNAVAILABLE  => 503;
const my $HTTP_TOO_MANY             => 429;
const my $IDENTITY_BAD_REQUEST_TEXT => 'identity request could not be accepted';
const my $LOGIN_LIMIT               => 10;
const my $LOGOUT_LIMIT              => 20;
const my $PASSWORD_LIMIT            => 5;
const my $REGISTER_LIMIT            => 5;
const my $SETTINGS_LIMIT            => 60;
const my $SHORT_WINDOW              => 60;
const my $LONG_WINDOW               => 300;
const my $PROFILE_THREADS           => 10;
const my $LOCALE_COOKIE             => 'gpforum_locale';
const my $THEME_COOKIE              => 'gpforum_theme';
const my $COOKIE_AGE                => 31_536_000;
const my %ACTION_LIMIT_FOR => (
    'identity.email_change'    => $PASSWORD_LIMIT,
    'identity.email_verify'    => $PASSWORD_LIMIT,
    'identity.logout'          => $LOGOUT_LIMIT,
    'identity.password_change' => $PASSWORD_LIMIT,
    'identity.password_reset'  => $PASSWORD_LIMIT,
    'identity.register'        => $REGISTER_LIMIT,
    'identity.settings'        => $SETTINGS_LIMIT,
);

sub write_rate_input {
    my ( $self, $input ) = @_;

    return {
        action         => $input->{action},
        actor_id       => $input->{actor_id},
        limit          => $self->write_limit_for( $input->{action} ),
        scope          => 'identity_http',
        window_seconds => $self->write_window_for( $input->{action} ),
    };
}

sub write_limit_for {
    my ( undef, $action ) = @_;

    if ( exists $ACTION_LIMIT_FOR{$action} ) {
        return $ACTION_LIMIT_FOR{$action};
    }

    return $LOGIN_LIMIT;
}

sub write_window_for {
    my ( undef, $action ) = @_;

    if ( $action eq 'identity.logout' ) {
        return $SHORT_WINDOW;
    }
    if ( $action eq 'identity.settings' ) {
        return $SHORT_WINDOW;
    }

    return $LONG_WINDOW;
}

sub profile_thread_limit {
    my ( undef, $requested ) = @_;

    return $requested || $PROFILE_THREADS;
}

sub locale_cookie_name {
    return $LOCALE_COOKIE;
}

sub theme_cookie_name {
    return $THEME_COOKIE;
}

sub preference_cookie_options {
    my ( undef, $now ) = @_;

    return {
        expires  => $now + $COOKIE_AGE,
        httponly => 1,
        path     => q{/},
        samesite => 'Lax',
    };
}

sub csrf_failure {
    my ( undef, $controller ) = @_;

    return $controller->render(
        text   => GPForum::Web::ErrorPayload->csrf_text,
        status => $HTTP_FORBIDDEN,
    );
}

sub rate_limited {
    my ( $self, $controller ) = @_;

    return $self->_json_or_text(
        $controller,
        {
            json   => GPForum::Web::ErrorPayload->identity_rate_limited,
            status => $HTTP_TOO_MANY,
            text   => GPForum::Web::ErrorPayload->rate_limited_text,
        }
    );
}

sub system_failure {
    my ( $self, $controller ) = @_;

    return $self->_json_or_text(
        $controller,
        {
            json   => GPForum::Web::ErrorPayload->system_failure,
            status => $HTTP_SERVER_ERROR,
            text   => GPForum::Web::ErrorPayload->system_failure()->{error},
        }
    );
}

sub service_unavailable {
    my ( $self, $controller ) = @_;

    return $self->_json_or_text(
        $controller,
        {
            json   => GPForum::Web::ErrorPayload->unavailable,
            status => $HTTP_SERVICE_UNAVAILABLE,
            text   => GPForum::Web::ErrorPayload->unavailable()->{error},
        }
    );
}

sub bad_request {
    my ( $self, $controller ) = @_;

    return $self->_json_or_text(
        $controller,
        {
            json   => GPForum::Web::ErrorPayload->bad_request,
            status => $HTTP_BAD_REQUEST,
            text   => $IDENTITY_BAD_REQUEST_TEXT,
        }
    );
}

sub _json_or_text {
    my ( $self, $controller, $input ) = @_;

    if ( $self->_wants_json($controller) ) {
        return $controller->render(
            json   => $input->{json},
            status => $input->{status},
        );
    }

    return $controller->render(
        text   => $input->{text},
        status => $input->{status},
    );
}

sub _wants_json {
    my ( undef, $controller ) = @_;

    return GPForum::Web::Access->new->wants_json($controller);
}

1;

__END__

=head1 NAME

GPForum::Web::IdentityAccess - Identity text and JSON error contracts.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    return GPForum::Web::IdentityAccess->new->csrf_failure($controller);

=head1 DESCRIPTION

Owns identity CSRF text, rate-limit hashes, public-profile thread limits,
locale/theme preference-cookie names and options, system-failure,
service-unavailable, and bad-request rendering. CSRF stays plaintext even
when the client asks for JSON. L<GPForum::Web::Guard> is not used.
Controllers still record security telemetry, call the rate limiter, write
cookies, and keep settings login redirects.

=head1 SUBROUTINES/METHODS

=head2 write_rate_input

Returns the C<identity_http> rate-limit arguments for an action.

=head2 write_limit_for

Returns 20 for logout, 60 for settings, 5 for register/password/email
including verification, and 10 for other identity writes including login.

=head2 write_window_for

Returns 60 seconds for logout and settings, otherwise 300.

=head2 profile_thread_limit

Returns a requested public-profile thread page size or the default of 10.

=head2 locale_cookie_name

Returns C<gpforum_locale>.

=head2 theme_cookie_name

Returns C<gpforum_theme>.

=head2 preference_cookie_options

Returns httponly C<Lax> cookie options whose expiry is the supplied epoch
plus one year.

=head2 csrf_failure

Renders C<ErrorPayload->csrf_text> as HTTP 403 text.

=head2 rate_limited

Renders the identity rate-limit JSON payload or the shared rate-limit text.

=head2 system_failure

Renders the shared internal-error payload as JSON or plaintext.

=head2 service_unavailable

Renders the shared unavailable payload as JSON or plaintext HTTP 503.

=head2 bad_request

Renders the identity-specific bad-request JSON payload or plaintext.

=head1 DIAGNOSTICS

JSON versus text negotiation uses L<GPForum::Web::Access>, except CSRF which
is always text.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, L<GPForum::Web::Access>, and
L<GPForum::Web::ErrorPayload>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Settings HTML unauthorized responses still flash and redirect from the
identity controller because they need i18n.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
