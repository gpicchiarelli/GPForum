package GPForum::Service::Identity::AuthStore;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Identity::Support;

our $VERSION = '0.001';

has credential_store => undef;
has password         => undef;
has schema           => undef;
has session_store    => undef;
has support => sub { return GPForum::Service::Identity::Support->new; };

sub authenticate_login {
    my ( $self, $input ) = @_;

    my $user = $self->_authenticatable_user( $input->{identifier} );
    if ( !$user ) {
        return _invalid_login();
    }

    return $self->_login_with_password( $user, $input );
}

sub _authenticatable_user {
    my ( $self, $identifier ) = @_;

    my $user = $self->_find_login_user(
        $self->support->normalize_identifier($identifier) );
    if ( !$user || $self->_deleted_user($user) ) {
        return;
    }

    return $user;
}

sub _login_with_password {
    my ( $self, $user, $input ) = @_;

    if ( !$self->_password_matches( $user, $input->{password} ) ) {
        return _invalid_login();
    }
    if ( $self->_pending_user($user) ) {
        return { error => 'unverified', ok => 0 };
    }

    return $self->_opened_login( $user, $input );
}

sub _pending_user {
    my ( $self, $user ) = @_;

    my $status = $self->support->column( $user, 'status' ) || q{};
    return $status eq 'pending' ? 1 : 0;
}

sub _opened_login {
    my ( $self, $user, $input ) = @_;

    my $session = $self->session_store->create_session( $user, $input );

    return {
        ok         => 1,
        session    => $session->{session},
        session_id =>
          $self->support->column( $session->{session}, 'session_id' ),
        user    => $user,
        user_id => $self->support->column( $user, 'id' ),
    };
}

sub _password_matches {
    my ( $self, $user, $password ) = @_;

    my $credential = $self->credential_store->active_password_credential(
        $self->support->column( $user, 'id' ) );
    if ( !$credential ) {
        return 0;
    }

    return $self->password->verify_password( $password,
        $self->support->column( $credential, 'secret_hash' ) );
}

sub _find_login_user {
    my ( $self, $identifier ) = @_;

    if ( !length $identifier ) {
        return;
    }

    return $self->_lookup_login_user($identifier);
}

sub _lookup_login_user {
    my ( $self, $identifier ) = @_;

    my $users = $self->schema->resultset('User');
    if ( $identifier =~ /[@]/msx ) {
        return $users->find( { email_normalized => $identifier } );
    }

    return $users->find( { username => $identifier } );
}

sub _deleted_user {
    my ( $self, $user ) = @_;

    my $status = $self->support->column( $user, 'status' ) || q{};
    return $status eq 'deleted' ? 1 : 0;
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
