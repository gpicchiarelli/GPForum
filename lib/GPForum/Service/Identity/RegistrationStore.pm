# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::RegistrationStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::UniqueConflict;

our $VERSION = '0.001';

const my $ID_CONSTRAINT => 'users_pkey';

has audit            => undef;
has credential_store => undef;
has id_service       => undef;
has schema           => undef;

sub create_registration ( $self, $registration ) {
    my $errors = $self->_duplicate_errors( $registration->{user} );
    if ( keys %{$errors} ) {
        return { errors => $errors, ok => 0 };
    }

    return $self->_stored_registration($registration);
}

sub _stored_registration ( $self, $registration ) {
    my ( $result, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_in_txn($registration); },
      );
    if ($result) {
        return { ok => 1, user => $result->{user} };
    }

    return $self->_registration_after_conflict( $registration, $error );
}

sub _insert_in_txn ( $self, $registration ) {
    return $self->schema->txn_do(
        sub {
            return $self->_insert_registration($registration);
        }
    );
}

sub _registration_after_conflict ( $self, $registration, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_registration_after_unique( $registration, $error );
}

sub _registration_after_unique ( $self, $registration, $error ) {
    if ( _user_id_conflict($error) ) {
        return $self->_retry_or_reuse_user($registration);
    }

    return $self->_duplicate_result($registration);
}

sub _retry_or_reuse_user ( $self, $registration ) {
    my $stored = $self->_user_by_id( $registration->{user}{id} );
    if ( $self->_same_open_user( $stored, $registration->{user} ) ) {
        return $self->_reuse_user( $stored, $registration );
    }

    return $self->_retry_user_id($registration);
}

sub _same_open_user ( $self, $stored, $user ) {
    if ( !$stored ) {
        return 0;
    }
    if ( !_same_text( _user_column( $stored, 'username' ), $user->{username} ) )
    {
        return 0;
    }

    return _same_text( _user_column( $stored, 'email_normalized' ),
        $user->{email_normalized} );
}

sub _reuse_user ( $self, $stored, $registration ) {
    my $user       = $registration->{user};
    my $credential = $registration->{credential};
    $self->credential_store->create_password_credential(
        {
            secret_hash => $credential->{secret_hash},
            type        => $credential->{type},
            user_id     => $user->{id},
        }
    );
    $self->audit->record_registration( $user, $self->id_service->uuid );

    return { ok => 1, user => $stored };
}

sub _user_by_id ( $self, $user_id ) {
    return $self->schema->resultset('User')->find( { id => $user_id } );
}

sub _user_column ( $row, $name ) {
    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }
    if ( $row && $row->can('get_column') ) {
        return $row->get_column($name);
    }

    my $undefined;
    return $undefined;
}

sub _same_text ( $stored, $candidate ) {
    if ( !defined $stored || !defined $candidate ) {
        return 0;
    }

    return $stored eq $candidate ? 1 : 0;
}

sub _retry_user_id ( $self, $registration ) {
    my ( $created, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            return $self->_insert_in_txn(
                $self->_reissued_registration($registration) );
        },
    );
    if ($created) {
        return { ok => 1, user => $created->{user} };
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reissued_registration ( $self, $registration ) {
    return {
        %{$registration},
        user => {
            %{ $registration->{user} }, id => $self->id_service->uuid,
        },
    };
}

sub _user_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _duplicate_result ( $self, $registration ) {
    return {
        errors => $self->_conflict_errors( $registration->{user} ),
        ok     => 0,
    };
}

sub _conflict_errors ( $self, $user ) {
    my $errors = $self->_duplicate_errors($user);
    if ( keys %{$errors} ) {
        return $errors;
    }

    return {
        email    => 'email is already registered',
        username => 'username is already registered',
    };
}

sub _duplicate_errors ( $self, $user ) {
    my %errors;
    $self->_username_error( $user, \%errors );
    $self->_email_error( $user, \%errors );

    return \%errors;
}

sub _username_error ( $self, $user, $errors ) {
    if ( $self->schema->resultset('User')
        ->find( { username => $user->{username} } ) )
    {
        $errors->{username} = 'username is already registered';
    }

    return;
}

sub _email_error ( $self, $user, $errors ) {
    if ( $self->schema->resultset('User')
        ->find( { email_normalized => $user->{email_normalized} } ) )
    {
        $errors->{email} = 'email is already registered';
    }

    return;
}

sub _insert_registration ( $self, $registration ) {
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
transaction. A unique race on insert returns the same field errors and does
not persist a second user or credential. A unique C<id> collision remints
the id once and does not return another user's account. A leftover unique
C<id> with this username and email reuses the account and inserts the
missing credential.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a schema with a User resultset plus credential and audit
collaborators supplied by the identity store facade.

=head1 DEPENDENCIES

Uses L<GPForum::Infrastructure::UniqueConflict> and the injected
collaborators.

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
