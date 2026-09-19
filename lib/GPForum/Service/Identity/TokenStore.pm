package GPForum::Service::Identity::TokenStore;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;
use GPForum::Service::SessionToken;

our $VERSION = '0.001';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has schema         => undef;
has session_tokens => sub { return GPForum::Service::SessionToken->new; };
has support        => sub { return GPForum::Service::Identity::Support->new; };

sub create_token {
    my ( $self, $input ) = @_;

    my $created_at = $self->clock->now_iso8601;
    my $raw_token  = $self->session_tokens->issue_token;
    my $expires_at = $self->support->iso8601_from_epoch(
        $self->clock->now_epoch + $input->{ttl_seconds} );
    my $token_id   = $self->id_service->uuid;
    my $token_hash = $self->session_tokens->hash_token($raw_token);
    my $row        = $self->_tokens->create(
        {
            created_at       => $created_at,
            email_normalized => $input->{email_normalized},
            expires_at       => $expires_at,
            metadata         => $input->{metadata} || {},
            token_hash       => $token_hash,
            token_id         => $token_id,
            token_type       => $input->{token_type},
            used_at          => undef,
            user_id          => $input->{user_id},
        }
    );

    return {
        expires_at => $expires_at,
        raw_token  => $raw_token,
        row        => $row,
        token_hash => $token_hash,
        token_id   => $token_id,
    };
}

sub consume_token {
    my ( $self, $token_type, $raw_token ) = @_;

    my $token_hash =
      $self->session_tokens->hash_token( $self->support->trim($raw_token) );
    $self->_lock_token_hash($token_hash);

    my $row = $self->_tokens->search(
        {
            token_hash => $token_hash,
            token_type => $token_type,
        },
        { rows => 1 }
    )->single;

    return $self->_finish_consumed_token($row);
}

sub _finish_consumed_token {
    my ( $self, $row ) = @_;

    my $validated = $self->_validate_token($row);
    if ( !$validated->{ok} ) {
        return $validated;
    }

    $self->support->update_row( $row,
        { used_at => $self->clock->now_iso8601 } );

    return {
        ok               => 1,
        email_normalized => $self->support->column( $row, 'email_normalized' ),
        row              => $row,
        token_id         => $self->support->column( $row, 'token_id' ),
        user_id          => $self->support->column( $row, 'user_id' ),
    };
}

sub _validate_token {
    my ( $self, $row ) = @_;

    if ( !$row ) {
        return { ok => 0, error => 'invalid_token' };
    }
    if ( defined $self->support->column( $row, 'used_at' ) ) {
        return { ok => 0, error => 'token_used' };
    }
    if ( $self->_token_expired($row) ) {
        return { ok => 0, error => 'token_expired' };
    }

    return { ok => 1 };
}

sub _token_expired {
    my ( $self, $row ) = @_;

    my $expires_at = $self->support->column( $row, 'expires_at' ) || q{};
    return $expires_at le $self->clock->now_iso8601 ? 1 : 0;
}

sub _lock_token_hash {
    my ( $self, $token_hash ) = @_;

    my $dbh = $self->_schema_dbh;
    if ( !$dbh ) {
        return;
    }

    my $locked = $dbh->selectrow_array(
        'SELECT token_id FROM identity_tokens WHERE token_hash = ? FOR UPDATE',
        undef, $token_hash
    );

    return $locked;
}

sub _schema_dbh {
    my ($self) = @_;

    my $storage = eval { return $self->schema->storage };
    if ( !$storage || !$storage->can('dbh') ) {
        return;
    }

    my $dbh = eval { return $storage->dbh };
    return $dbh;
}

sub _tokens {
    my ($self) = @_;

    return $self->schema->resultset('IdentityToken');
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::TokenStore - Identity token persistence.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Identity::TokenStore->new(
        schema => $schema,
    );

=head1 DESCRIPTION

Issues and consumes hashed identity tokens for password reset, email
change, and registration verification.

=head1 SUBROUTINES/METHODS

=head2 create_token

Creates a typed identity token and returns the raw token once.

=head2 consume_token

Locks, validates, and marks a token as used.

=head1 DIAGNOSTICS

Invalid, used, or expired tokens return C<invalid_token>, C<token_used>, or
C<token_expired>.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a DBIx::Class schema with an C<IdentityToken> resultset.

=head1 DEPENDENCIES

Uses L<GPForum::Service::Identity::Support> and L<GPForum::Service::SessionToken>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Token rows are locked with C<FOR UPDATE> when a database handle is available.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
