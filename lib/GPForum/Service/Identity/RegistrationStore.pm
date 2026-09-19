package GPForum::Service::Identity::RegistrationStore;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has audit            => undef;
has credential_store => undef;
has id_service       => undef;
has schema           => undef;

sub create_registration {
    my ( $self, $registration ) = @_;

    my $errors = $self->_duplicate_errors( $registration->{user} );
    if ( keys %{$errors} ) {
        return { errors => $errors, ok => 0 };
    }

    return $self->_stored_registration($registration);
}

sub _stored_registration {
    my ( $self, $registration ) = @_;

    my $result = $self->schema->txn_do(
        sub {
            return $self->_insert_registration($registration);
        }
    );

    return { ok => 1, user => $result->{user} };
}

sub _duplicate_errors {
    my ( $self, $user ) = @_;

    my %errors;
    $self->_username_error( $user, \%errors );
    $self->_email_error( $user, \%errors );

    return \%errors;
}

sub _username_error {
    my ( $self, $user, $errors ) = @_;

    if ( $self->schema->resultset('User')
        ->find( { username => $user->{username} } ) )
    {
        $errors->{username} = 'username is already registered';
    }

    return;
}

sub _email_error {
    my ( $self, $user, $errors ) = @_;

    if ( $self->schema->resultset('User')
        ->find( { email_normalized => $user->{email_normalized} } ) )
    {
        $errors->{email} = 'email is already registered';
    }

    return;
}

sub _insert_registration {
    my ( $self, $registration ) = @_;

    my $user       = $registration->{user};
    my $credential = $registration->{credential};
    $user->{password_hash} ||= $credential->{secret_hash};

    my $created_user = $self->schema->resultset('User')->create($user);
    $self->credential_store->create_password_credential(
        {
            secret_hash => $credential->{secret_hash},
            type        => $credential->{type},
            user_id     => $user->{id},
        }
    );
    $self->audit->record_registration( $user, $self->id_service->uuid );

    return { user => $created_user };
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::RegistrationStore - Registration persistence.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = $store->create_registration($registration);

=head1 DESCRIPTION

Owns duplicate-account checks and transactional user/credential persistence
for prepared registrations. The identity store facade delegates
C<create_registration> so HTTP and workflow callers keep a stable API.

=head1 SUBROUTINES/METHODS

=head2 create_registration

Persists a prepared registration inside a transaction.

=head1 DIAGNOSTICS

Duplicate usernames and emails return field errors without opening a
transaction.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a schema with a User resultset plus credential and audit
collaborators supplied by the identity store facade.

=head1 DEPENDENCIES

None beyond the injected collaborators.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not hash passwords; C<Identity::Registration> prepares the credential
hash before this store runs.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
