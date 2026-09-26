# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::CookieSession;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Web::Access;

our $VERSION = '0.001';

const my $SESSION_SECONDS => 2_592_000;

has access => sub { return GPForum::Web::Access->new; };

sub has_server_session ( $self, $controller ) {
    if ( !$self->access->has_text( $controller->session('session_id') ) ) {
        return 0;
    }
    if ( !$self->access->has_text( $self->access->user_id($controller) ) ) {
        return 0;
    }

    return 1;
}

sub expired ( $, $controller, $now ) {
    my $expires_at = $controller->session('session_expires_at_epoch');
    if ( !defined $expires_at ) {
        return 0;
    }

    return $expires_at > $now ? 0 : 1;
}

sub session_seconds {
    return $SESSION_SECONDS;
}

sub expires_at ( $, $now ) {
    return int( $now + $SESSION_SECONDS );
}

sub clear ( $self, $controller ) {
    $self->_delete_keys(
        $controller,
        [
            qw(user_id session_id session_token login_rotation session_expires_at_epoch)
        ]
    );
    $controller->session( expires => 1 );

    return;
}

sub replace_login ( $self, $controller, $input ) {
    $self->_delete_keys(
        $controller,
        [
            qw(user_id session_id session_token login_rotation session_expires_at_epoch preferred_locale preferred_theme preferred_timezone)
        ]
    );
    $controller->session( $self->login_values($input) );

    return;
}

sub login_values ( $self, $input ) {
    my %values = (
        login_rotation           => $input->{rotation},
        session_expires_at_epoch => $input->{expires_at},
        session_id               => $input->{session_id},
        session_token            => $input->{session_token},
        user_id                  => $input->{user_id},
    );
    $self->_maybe_set( \%values, 'preferred_locale',
        $input->{preferred_locale} );
    $self->_maybe_set( \%values, 'preferred_theme', $input->{preferred_theme} );
    $self->_maybe_set( \%values, 'preferred_timezone',
        $input->{preferred_timezone} );

    return %values;
}

sub validation_reason ( $, $validation ) {
    if ( !$validation ) {
        return 'validation_failed';
    }

    return $validation->{error} || 'validation_failed';
}

sub _delete_keys ( $, $controller, $keys ) {
    my $session = $controller->session;
    delete @{$session}{ @{$keys} };

    return;
}

sub _maybe_set ( $, $values, $name, $value ) {
    if ( defined $value ) {
        $values->{$name} = $value;
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Web::CookieSession - Cookie-session field ownership.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $cookies = GPForum::Web::CookieSession->new;
    if ( $cookies->expired( $controller, time ) ) {
        $cookies->clear($controller);
    }

=head1 DESCRIPTION

Owns cookie-session presence, 30-day login duration, expiry, clearing, and
login-value assembly. It does not validate server-side session rows, render
errors, or record telemetry. Bootstrap identity and the identity controller
keep those responsibilities.

=head1 SUBROUTINES/METHODS

=head2 has_server_session

True when both C<session_id> and C<user_id> cookies are present.

=head2 expired

True when C<session_expires_at_epoch> is defined and not after C<$now>.

=head2 session_seconds

Returns the authenticated cookie-session lifetime of 2_592_000 seconds.

=head2 expires_at

Returns the integer epoch C<$now> plus the cookie-session lifetime.

=head2 clear

Deletes server-session keys and expires the Mojolicious session cookie.

=head2 replace_login

Resets login keys and writes a new authenticated cookie session.

=head2 login_values

Returns the hash written into the cookie session at login.

=head2 validation_reason

Maps a missing or failed store validation to C<validation_failed> or the
store error.

=head1 DIAGNOSTICS

These methods return booleans, hashes, or reason strings. HTTP status mapping
stays in bootstrap identity and identity controllers.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<GPForum::Web::Access>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Invalidation does not delete locale and theme cookies; login replacement does.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
