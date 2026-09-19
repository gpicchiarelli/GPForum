package GPForum::Service::Identity::CredentialStore;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;

our $VERSION = '0.001';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has schema  => undef;
has support => sub { return GPForum::Service::Identity::Support->new; };

sub create_password_credential {
    my ( $self, $input ) = @_;

    return $self->_credentials->create(
        {
            id          => $self->id_service->uuid,
            secret_hash => $input->{secret_hash},
            type        => $input->{type} || 'password',
            user_id     => $input->{user_id},
        }
    );
}

sub active_password_credential {
    my ( $self, $user_id ) = @_;

    if ( !$self->support->has_text($user_id) ) {
        return;
    }

    return $self->_credentials->search(
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

sub rotate_password_credential {
    my ( $self, $input ) = @_;

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

sub _revoke_active_password_credentials {
    my ( $self, $user_id, $revoked_at ) = @_;

    my @active = $self->_credentials->search(
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

sub _credentials {
    my ($self) = @_;

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

Inserts a password credential row.

=head2 active_password_credential

Returns the newest non-revoked password credential for a user.

=head2 rotate_password_credential

Revokes active password credentials and inserts a replacement.

=head1 DIAGNOSTICS

None. Missing users yield an empty credential.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a DBIx::Class schema with a C<Credential> resultset.

=head1 DEPENDENCIES

Uses L<GPForum::Service::Identity::Support>.

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
