# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::AuthStore;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Service::Identity::Support;

our $VERSION = '0.001';

has credential_store => undef;
has password         => undef;
has schema           => undef;
has session_store    => undef;
has support => sub { return GPForum::Service::Identity::Support->new; };

sub authenticate_login ( $self, $input ) {
    my $user = $self->_authenticatable_user( $input->{identifier} );
    if ( !$user ) {
        return $self->_invalid_login_after_work( $input->{password} );
    }

    return $self->_login_with_password( $user, $input );
}

sub _authenticatable_user ( $self, $identifier ) {
    my $user = $self->_find_login_user(
        $self->support->normalize_identifier($identifier) );
    if ( !$user || $self->_deleted_user($user) ) {
        my $undefined;
        return $undefined;
    }

    return $user;
}

sub _login_with_password ( $self, $user, $input ) {
    if ( !$self->_password_matches( $user, $input->{password} ) ) {
        return _invalid_login();
    }
    if ( $self->_pending_user($user) ) {
        return { error => 'unverified', ok => 0 };
    }

    return $self->_opened_login( $user, $input );
}

sub _pending_user ( $self, $user ) {
    my $status = $self->support->column( $user, 'status' ) || q{};
    return $status eq 'pending' ? 1 : 0;
}

sub _opened_login ( $self, $user, $input ) {
    my $session = $self->session_store->create_session( $user, $input );

    return {
        ok         => 1,
        session    => $session->{session},
        session_id =>
          $self->support->column( $session->{session}, 'session_id' ),
        session_token => $session->{session_token},
        user          => $user,
        user_id       => $self->support->column( $user, 'id' ),
    };
}

sub _password_matches ( $self, $user, $password ) {
    my $credential = $self->credential_store->active_password_credential(
        $self->support->column( $user, 'id' ) );
    if ( !$credential ) {
        return $self->_invalid_login_after_work($password)->{ok};
    }

    return $self->password->verify_password( $password,
        $self->support->column( $credential, 'secret_hash' ) );
}

sub _find_login_user ( $self, $identifier ) {
    if ( !length $identifier ) {
        my $undefined;
        return $undefined;
    }

    return $self->_lookup_login_user($identifier);
}

sub _lookup_login_user ( $self, $identifier ) {
    my $users = $self->schema->resultset('User');
    if ( $identifier =~ /[@]/msx ) {
        return $users->find( { email_normalized => $identifier } );
    }

    return $users->find( { username => $identifier } );
}

sub _deleted_user ( $self, $user ) {
    my $status = $self->support->column( $user, 'status' ) || q{};
    return $status eq 'deleted' ? 1 : 0;
}

# The same Argon2 work as a wrong password, then the same answer: with no
# account to check, a login answered at once, and its speed said which
# usernames and addresses exist.
sub _invalid_login_after_work ( $self, $password ) {
    $self->password->verify_password( $password, $self->password->decoy_hash );

    return _invalid_login();
}

sub _invalid_login {
    return { error => 'invalid_credentials', ok => 0 };
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::AuthStore - Login credential verification.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = $store->authenticate_login(
        {
            identifier => $identifier,
            password   => $password,
        }
    );

=head1 DESCRIPTION

Owns login authentication and server-session creation. The identity store
facade delegates C<authenticate_login> so HTTP and workflow callers keep a
stable API. Failed logins remain non-enumerative.

=head1 SUBROUTINES/METHODS

=head2 authenticate_login

Verifies a password credential and opens a server session.

=head1 DIAGNOSTICS

Unknown identifiers, deleted users, and wrong passwords all return
C<invalid_credentials>. Matching credentials on a pending account return
C<unverified> without opening a session.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a schema with a User resultset plus credential, password, and session
collaborators supplied by the identity store facade.

=head1 DEPENDENCIES

Uses L<GPForum::Service::Identity::Support>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Login does not distinguish missing accounts from wrong passwords.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
