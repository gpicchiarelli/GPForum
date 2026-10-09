# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::RegistrationStore;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $ID_CONSTRAINT => 'users_pkey';

__PACKAGE__->requires(qw(audit credential_store id_service schema));

# A username or address taken since the look-up is refused as the look-up
# refuses it. A minted user id already stored is this registration's,
# committed by an earlier attempt, or another account's, and then a new id is
# minted.
sub create_registration ( $self, $registration ) {
    my $errors = $self->_duplicate_errors( $registration->{user} );
    if ( keys %{$errors} ) {
        return { errors => $errors, ok => 0 };
    }

    my ( $result, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_in_txn($registration); } );
    if ($result) {
        return { ok => 1, user => $result->{user} };
    }

    my $conflict = GPForum::X::Conflict->caught($error);
    if ( !$conflict ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !$conflict->on($ID_CONSTRAINT) ) {
        $errors = $self->_duplicate_errors( $registration->{user} );
        return {
            errors => keys %{$errors}
            ? $errors
            : {
                email    => 'email is already registered',
                username => 'username is already registered',
            },
            ok => 0,
        };
    }

    my $stored = $self->schema->resultset('User')
      ->find( { id => $registration->{user}{id} } );
    if ( $self->_same_open_user( $stored, $registration->{user} ) ) {

        # The transaction that inserted the account rolled back on the
        # conflict, so the rest of the registration goes in a transaction of
        # its own (ADR 0110). It ran in autocommit: a failed audit left the
        # credential and the event behind, a registration half written.
        return $self->schema->txn_do(
            sub {
                $self->_complete_registration($registration);
                return { ok => 1, user => $stored };
            }
        );
    }

    my $reissued = {
        %{$registration},
        user => { %{ $registration->{user} }, id => $self->id_service->uuid },
    };
    my ( $created, $retry_error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_in_txn($reissued); } );
    if ($created) {
        return { ok => 1, user => $created->{user} };
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($retry_error);
}

sub _insert_in_txn ( $self, $registration ) {
    return $self->schema->txn_do(
        sub {
            my $user       = $registration->{user};
            my $credential = $registration->{credential};
            $user->{password_hash} ||= $credential->{secret_hash};

            my $created_user = $self->schema->resultset('User')->create($user);
            $self->_complete_registration($registration);

            return { user => $created_user };
        }
    );
}

# The same username and address: the row is this registration's account.
sub _same_open_user ( $self, $stored, $user ) {
    if ( !$stored ) {
        return 0;
    }
    for my $column (qw(username email_normalized)) {
        my $value = _user_column( $stored, $column );
        if (   !defined $value
            || !defined $user->{$column}
            || $value ne $user->{$column} )
        {
            return 0;
        }
    }

    return 1;
}

sub _complete_registration ( $self, $registration ) {
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

    return;
}

sub _user_column ( $row, $name ) {
    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }
    if ( $row && $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return undef;
}

sub _duplicate_errors ( $self, $user ) {
    my $users = $self->schema->resultset('User');
    my %errors;
    if ( $users->find( { username => $user->{username} } ) ) {
        $errors{username} = 'username is already registered';
    }
    if ( $users->find( { email_normalized => $user->{email_normalized} } ) ) {
        $errors{email} = 'email is already registered';
    }

    return \%errors;
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
missing credential, event and audit in one transaction of their own, so a
failure there leaves none of them behind.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a schema with a User resultset plus credential and audit
collaborators supplied by the identity store facade.

=head1 DEPENDENCIES

Uses L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::X::Conflict> and
the injected collaborators.

Extends L<GPForum::Base>: built without C<audit>, C<credential_store>,
C<id_service> or C<schema> it throws L<GPForum::X::Argument>.

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
