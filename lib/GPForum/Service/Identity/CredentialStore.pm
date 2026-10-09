# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::CredentialStore;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my @CREDENTIAL_COLUMNS =>
  qw(id user_id type secret_hash revoked_at created_at);
const my $ID_CONSTRAINT     => 'credentials_pkey';
const my $ACTIVE_CONSTRAINT => 'idx_credentials_active_password_unique';

# How many rotations may commit while one waits for the credentials before
# it gives up; each round is another rotation that got there first.
const my $LOCK_ROUNDS => 3;

# A credential is revoked at the time given, or at its own creation when
# that is later: a rotation that waited for another locks the credential the
# other just created, and another host's clock can run behind the one that
# stamped it. credentials_revoked_after_created_check refuses the earlier.
const my $NOT_BEFORE_CREATION => 'GREATEST(CAST(? AS timestamptz), created_at)';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
__PACKAGE__->requires(qw(schema));
has support => sub { return GPForum::Service::Identity::Support->new; };

# created_at comes from the store's clock, as revoked_at does: the database
# default stamped creation by the server's clock while revocation took the
# application's, and an application clock behind the server's revoked a
# credential before it was created, which credentials_revoked_after_created
# refuses. The session and token stores stamp their rows the same way.
#
# A member's active password is answered rather than doubled, whether it was
# there before or a concurrent insert committed it first. A minted id already
# stored is this very credential, committed by an earlier attempt, or another
# one, and then a new id is minted.
sub create_password_credential ( $self, $input ) {
    my $existing = $self->active_password_credential( $input->{user_id} );
    if ($existing) {
        return $self->_skipped_credential($existing);
    }

    my $row = {
        created_at  => $self->clock->now_iso8601,
        id          => $self->id_service->uuid,
        secret_hash => $input->{secret_hash},
        type        => $input->{type} || 'password',
        user_id     => $input->{user_id},
    };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_credentials->create($row); } );
    if ($created) {
        return $created;
    }

    my $conflict = GPForum::X::Conflict->caught($error);
    if ( $conflict && $conflict->on($ID_CONSTRAINT) ) {
        my $stored = $self->_credentials->find( { id => $row->{id} } );
        if ( $self->_same_open_credential( $stored, $row ) ) {
            return $self->_skipped_credential($stored);
        }

        my $reissued = { %{$row}, id => $self->id_service->uuid };
        my ( $retried, $retry_error ) =
          GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
            sub { return $self->_credentials->create($reissued); } );
        if ($retried) {
            return $retried;
        }
        GPForum::Infrastructure::UniqueConflict->rethrow($retry_error);
    }
    if ( $conflict && $conflict->on($ACTIVE_CONSTRAINT) ) {
        $existing = $self->active_password_credential( $input->{user_id} );
        if ($existing) {
            return $self->_skipped_credential($existing);
        }
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

# A leftover of this very insert is this member's, of this type, and still
# open. A revoked credential under the id was reused all the same: the store
# answered with it as the active password, inserted none, and left the
# member with no password at all.
sub _same_open_credential ( $self, $stored, $row ) {
    if ( !$stored || defined $self->support->column( $stored, 'revoked_at' ) ) {
        return 0;
    }
    for my $column (qw(type user_id)) {
        my $value = $self->support->column( $stored, $column );
        if (   !defined $value
            || !defined $row->{$column}
            || $value ne $row->{$column} )
        {
            return 0;
        }
    }

    return 1;
}

sub _skipped_credential ( $self, $existing ) {
    my %row =
      map { $_ => scalar $self->support->column( $existing, $_ ) }
      @CREDENTIAL_COLUMNS;

    return { %row, skipped => 1 };
}

sub active_password_credential ( $self, $user_id ) {
    if ( !$self->support->has_text($user_id) ) {
        return undef;
    }

    return $self->_credentials->search_rs(
        {
            revoked_at => undef,
            type       => 'password',
            user_id    => $user_id,
        },
        {
            order_by => { -desc => 'created_at' },
            rows     => 1,
        }
    )->single;
}

# The credential a login verified, FOR SHARE, while it is still this
# member's active password; undef once a rotation revoked it. Held until the
# caller's transaction ends, so a rotation that has not reached the row yet
# waits for that transaction, and one that already has makes this wait for
# it and then find the row revoked.
sub hold_active_password_credential ( $self, $user_id, $credential_id ) {
    if (   !$self->support->has_text($user_id)
        || !$self->support->has_text($credential_id) )
    {
        return undef;
    }

    return $self->_credentials->search_rs(
        {
            id         => $credential_id,
            revoked_at => undef,
            type       => 'password',
            user_id    => $user_id,
        },
        { for => 'shared' }
    )->single;
}

# The member's active password credentials, locked FOR UPDATE until the
# caller's transaction ends, so the caller decides on the password the
# member has now and no other reset or change can replace it before the
# caller commits. A rotation that commits while this waits for its lock
# revokes the rows waited for, and the credential it creates is not in the
# statement's snapshot: the statement finds nothing. A rotation went on from
# there as if the member had no password: a reset answered ok and left the
# password the other one set, a change verified against a password already
# replaced overwrote the reset. The next statement sees the new credential
# and locks that.
sub lock_active_password_credentials ( $self, $user_id ) {
    for ( 1 .. $LOCK_ROUNDS ) {
        my @locked = $self->_credentials->search_rs(
            {
                revoked_at => undef,
                type       => 'password',
                user_id    => $user_id,
            },
            { for => 'update' }
        )->all;
        if (@locked) {
            return @locked;
        }
        if ( !$self->active_password_credential($user_id) ) {
            return;
        }
    }

    croak "the password of $user_id changed $LOCK_ROUNDS times while"
      . ' this waited for it; try again';
}

# Every active password is revoked before the new one is created, under the
# lock above: a login holding one of them FOR SHARE opens its session before
# the rotation goes on, and the caller's revocation of the member's
# sessions, later in the same transaction, then sees it.
sub rotate_password_credential ( $self, $input ) {
    my $user_id = $input->{user_id};
    my @active  = $self->lock_active_password_credentials($user_id);
    if (@active) {
        $self->_credentials->search_rs(
            {
                id =>
                  [ map { scalar $self->support->column( $_, 'id' ) } @active ]
            }
        )->update(
            {
                revoked_at =>
                  \[ $NOT_BEFORE_CREATION, $self->clock->now_iso8601 ]
            }
        );
    }

    return $self->create_password_credential(
        {
            secret_hash => $input->{secret_hash},
            type        => 'password',
            user_id     => $user_id,
        }
    );
}

sub _credentials ($self) {
    return $self->schema->resultset('Credential');
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::CredentialStore - Password credential persistence.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Identity::CredentialStore->new(
        schema => $schema,
    );

=head1 DESCRIPTION

Creates, locates, and rotates password credentials.

=head1 SUBROUTINES/METHODS

=head2 create_password_credential

Inserts a password credential row, stamped C<created_at> by the store's
clock, the clock that later stamps its C<revoked_at>. An already-active
password for that user is returned with C<skipped> and is not inserted
again. A unique C<id> collision remints the id once and does not return
another user's credential, nor a revoked one. A leftover unique C<id> with
this user and type, still open, reuses the active password.

=head2 active_password_credential

Returns the newest non-revoked password credential for a user.

=head2 hold_active_password_credential

Takes a user id and a credential id. Inside the caller's transaction, reads
that password credential C<FOR SHARE> while it is still the member's and not
revoked, and returns it; returns undef otherwise. A login holds the
credential it verified this way while it opens its session.

=head2 lock_active_password_credentials

Takes a user id. Inside the caller's transaction, locks the member's active
password credentials C<FOR UPDATE> and returns them, or returns nothing when
the member has none. When a concurrent rotation commits while this waits,
the credential it created is locked instead: the caller always holds the
password the member has when it goes on. Croaks when three rotations commit
in a row while it waits.

=head2 rotate_password_credential

Locks the member's active password credentials as
L</lock_active_password_credentials> does, revokes them -- at the store's
clock, or at a credential's own C<created_at> when that is later -- and
inserts a replacement. Meant to run in the transaction that then revokes the
member's sessions, so a login holding the old credential either commits its
session first, and that session is revoked, or finds the credential revoked
and opens none.

=head1 DIAGNOSTICS

C<lock_active_password_credentials> croaks C<the password of ID changed 3
times while this waited for it; try again>. Missing users yield an empty
credential.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a DBIx::Class schema with a C<Credential> resultset.

=head1 DEPENDENCIES

Uses L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::X::Conflict> and
L<GPForum::Service::Identity::Support>.

Extends L<GPForum::Base>: built without C<schema> it throws
L<GPForum::X::Argument>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Only password credentials are managed here.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
