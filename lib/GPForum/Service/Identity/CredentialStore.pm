# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::CredentialStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;

our $VERSION = '0.001';

const my @CREDENTIAL_COLUMNS =>
  qw(id user_id type secret_hash revoked_at created_at);
const my $ID_CONSTRAINT     => 'credentials_pkey';
const my $ACTIVE_CONSTRAINT => 'idx_credentials_active_password_unique';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has schema  => undef;
has support => sub { return GPForum::Service::Identity::Support->new; };

sub create_password_credential ( $self, $input ) {
    my $existing = $self->active_password_credential( $input->{user_id} );
    if ($existing) {
        return $self->_skipped_credential($existing);
    }

    return $self->_insert_or_reuse_credential($input);
}

sub _insert_or_reuse_credential ( $self, $input ) {
    my $ctx = {
        input => $input,
        row   => $self->_credential_row($input),
    };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_credential( $ctx->{row} ); },
      );
    if ($created) {
        return $created;
    }

    return $self->_credential_after_conflict( $ctx, $error );
}

sub _credential_after_conflict ( $self, $ctx, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_credential_after_unique( $ctx, $error );
}

sub _credential_after_unique ( $self, $ctx, $error ) {
    if ( _credential_id_conflict($error) ) {
        return $self->_retry_or_reuse_credential($ctx);
    }
    if ( _active_password_conflict($error) ) {
        return $self->_reuse_active_password( $ctx->{input}, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _retry_or_reuse_credential ( $self, $ctx ) {
    my $stored = $self->_credential_by_id( $ctx->{row}{id} );
    if ( $self->_same_open_credential( $stored, $ctx->{input} ) ) {
        return $self->_skipped_credential($stored);
    }

    return $self->_retry_credential_id($ctx);
}

sub _same_open_credential ( $self, $stored, $input ) {
    if ( !$stored ) {
        return 0;
    }

    return _same_text( $self->support->column( $stored, 'user_id' ),
        $input->{user_id} );
}

sub _retry_credential_id ( $self, $ctx ) {
    $ctx->{row} = { %{ $ctx->{row} }, id => $self->id_service->uuid, };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_credential( $ctx->{row} ); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reuse_active_password ( $self, $input, $error ) {
    my $existing = $self->active_password_credential( $input->{user_id} );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_skipped_credential($existing);
}

sub _credential_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _active_password_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ACTIVE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_credential ( $self, $row ) {
    return $self->_credentials->create($row);
}

sub _credential_row ( $self, $input ) {
    return {
        id          => $self->id_service->uuid,
        secret_hash => $input->{secret_hash},
        type        => $input->{type} || 'password',
        user_id     => $input->{user_id},
    };
}

sub _credential_by_id ( $self, $credential_id ) {
    return $self->_credentials->find( { id => $credential_id } );
}

sub _same_text ( $stored, $candidate ) {
    if ( !defined $stored || !defined $candidate ) {
        return 0;
    }

    return $stored eq $candidate ? 1 : 0;
}

sub _skipped_credential ( $self, $existing ) {
    return { %{ $self->_credential_hash($existing) }, skipped => 1 };
}

sub _credential_hash ( $self, $credential ) {
    my %row;
    for my $name (@CREDENTIAL_COLUMNS) {
        $row{$name} = $self->support->column( $credential, $name );
    }

    return \%row;
}

sub active_password_credential ( $self, $user_id ) {
    if ( !$self->support->has_text($user_id) ) {
        my $undefined;
        return $undefined;
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

sub rotate_password_credential ( $self, $input ) {
    my $now     = $self->clock->now_iso8601;
    my $user_id = $input->{user_id};
    $self->_revoke_active_password_credentials( $user_id, $now );

    return $self->create_password_credential(
        {
            secret_hash => $input->{secret_hash},
            type        => 'password',
            user_id     => $user_id,
        }
    );
}

sub _revoke_active_password_credentials ( $self, $user_id, $revoked_at ) {
    my @active = $self->_credentials->search_rs(
        {
            revoked_at => undef,
            type       => 'password',
            user_id    => $user_id,
        }
    )->all;

    for my $credential (@active) {
        $self->support->update_row( $credential,
            { revoked_at => $revoked_at } );
    }

    return;
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

Inserts a password credential row. An already-active password for that user
is returned with C<skipped> and is not inserted again. A unique C<id>
collision remints the id once and does not return another user's credential.
A leftover unique C<id> with this user reuses the active password.

=head2 active_password_credential

Returns the newest non-revoked password credential for a user.

=head2 rotate_password_credential

Revokes active password credentials and inserts a replacement.

=head1 DIAGNOSTICS

None. Missing users yield an empty credential.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a DBIx::Class schema with a C<Credential> resultset.

=head1 DEPENDENCIES

Uses L<GPForum::Infrastructure::UniqueConflict> and
L<GPForum::Service::Identity::Support>.

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
