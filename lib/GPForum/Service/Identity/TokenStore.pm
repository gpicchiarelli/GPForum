# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::TokenStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;
use GPForum::Service::SessionToken;

our $VERSION = '0.001';

const my $HASH_CONSTRAINT => 'identity_tokens_hash_key';
const my $ID_CONSTRAINT   => 'identity_tokens_pkey';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has schema         => undef;
has session_tokens => sub { return GPForum::Service::SessionToken->new; };
has support        => sub { return GPForum::Service::Identity::Support->new; };

sub create_token ( $self, $input ) {
    my $issued = $self->_issued_token($input);
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_issued($issued); },
      );
    if ($created) {
        return $created;
    }

    return $self->_reuse_after_conflict( $issued, $error );
}

sub _insert_issued ( $self, $issued ) {
    my $row = $self->_tokens->create( $issued->{row} );

    return {
        expires_at => $issued->{expires_at},
        raw_token  => $issued->{raw_token},
        row        => $row,
        token_hash => $issued->{token_hash},
        token_id   => $issued->{token_id},
    };
}

sub _reuse_after_conflict ( $self, $issued, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_token_after_unique( $issued, $error );
}

sub _token_after_unique ( $self, $issued, $error ) {
    if ( _token_id_conflict($error) ) {
        return $self->_retry_or_reuse_token($issued);
    }
    if ( _hash_key_conflict($error) ) {
        return $self->_retry_token_hash($issued);
    }

    return $self->_rotate_open_token( $issued, $error );
}

sub _rotate_open_token ( $self, $issued, $error ) {
    my $existing = $self->_unused_token( $issued->{row} );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_rotate_token( $existing, $issued );
}

sub _retry_or_reuse_token ( $self, $issued ) {
    my $stored = $self->_token_by_id( $issued->{token_id} );
    if ( $self->_same_issued_token( $stored, $issued ) ) {
        return $self->_skipped_token($stored);
    }

    return $self->_retry_token_id($issued);
}

sub _same_issued_token ( $self, $stored, $issued ) {
    if ( !$stored ) {
        return 0;
    }
    if (
        !_same_text(
            $self->support->column( $stored, 'user_id' ),
            $issued->{row}{user_id}
        )
      )
    {
        return 0;
    }

    return _same_text( $self->support->column( $stored, 'token_hash' ),
        $issued->{token_hash} );
}

sub _skipped_token ( $self, $stored ) {
    return {
        row        => $stored,
        skipped    => 1,
        token_hash => $self->support->column( $stored, 'token_hash' ),
        token_id   => $self->support->column( $stored, 'token_id' ),
    };
}

sub _token_by_id ( $self, $token_id ) {
    return $self->_tokens->find( { token_id => $token_id } );
}

sub _same_text ( $stored, $candidate ) {
    if ( !defined $stored || !defined $candidate ) {
        return 0;
    }

    return $stored eq $candidate ? 1 : 0;
}

sub _retry_token_id ( $self, $issued ) {
    my ( $created, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            return $self->_insert_issued( $self->_reissued_token_id($issued) );
        },
    );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reissued_token_id ( $self, $issued ) {
    my $token_id = $self->id_service->uuid;

    return {
        expires_at => $issued->{expires_at},
        raw_token  => $issued->{raw_token},
        token_hash => $issued->{token_hash},
        token_id   => $token_id,
        row        => {
            %{ $issued->{row} }, token_id => $token_id,
        },
    };
}

sub _token_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _retry_token_hash ( $self, $issued ) {
    my ( $created, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            return $self->_insert_issued( $self->_rehashed_issued($issued) );
        },
    );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _rehashed_issued ( $self, $issued ) {
    my $raw_token  = $self->session_tokens->issue_token;
    my $token_hash = $self->session_tokens->hash_token($raw_token);

    return {
        expires_at => $issued->{expires_at},
        raw_token  => $raw_token,
        token_hash => $token_hash,
        token_id   => $issued->{token_id},
        row        => {
            %{ $issued->{row} }, token_hash => $token_hash,
        },
    };
}

sub _hash_key_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $HASH_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _unused_token ( $self, $input ) {
    if ( !$self->support->has_text( $input->{user_id} ) ) {
        my $undefined;
        return $undefined;
    }

    return $self->_tokens->search_rs(
        {
            token_type => $input->{token_type},
            used_at    => undef,
            user_id    => $input->{user_id},
        },
        { rows => 1 },
    )->single;
}

sub _rotate_token ( $self, $row, $issued ) {
    $self->support->update_row(
        $row,
        {
            email_normalized => $issued->{row}{email_normalized},
            expires_at       => $issued->{expires_at},
            metadata         => $issued->{row}{metadata},
            token_hash       => $issued->{token_hash},
        }
    );

    return {
        expires_at => $issued->{expires_at},
        raw_token  => $issued->{raw_token},
        rotated    => 1,
        row        => $row,
        token_hash => $issued->{token_hash},
        token_id   => $self->support->column( $row, 'token_id' ),
    };
}

sub _issued_token ( $self, $input ) {
    my $created_at = $self->clock->now_iso8601;
    my $raw_token  = $self->session_tokens->issue_token;
    my $expires_at = $self->support->iso8601_from_epoch(
        $self->clock->now_epoch + $input->{ttl_seconds} );
    my $token_id   = $self->id_service->uuid;
    my $token_hash = $self->session_tokens->hash_token($raw_token);

    return {
        expires_at => $expires_at,
        raw_token  => $raw_token,
        token_hash => $token_hash,
        token_id   => $token_id,
        row        => {
            created_at       => $created_at,
            email_normalized => $input->{email_normalized},
            expires_at       => $expires_at,
            metadata         => $input->{metadata} || {},
            token_hash       => $token_hash,
            token_id         => $token_id,
            token_type       => $input->{token_type},
            used_at          => undef,
            user_id          => $input->{user_id},
        },
    };
}

sub consume_token ( $self, $token_type, $raw_token ) {
    my $token_hash =
      $self->session_tokens->hash_token( $self->support->trim($raw_token) );
    $self->_lock_token_hash($token_hash);

    my $row = $self->_tokens->search_rs(
        {
            token_hash => $token_hash,
            token_type => $token_type,
        },
        { rows => 1 }
    )->single;

    return $self->_finish_consumed_token($row);
}

sub _finish_consumed_token ( $self, $row ) {
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

sub _validate_token ( $self, $row ) {
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

sub _token_expired ( $self, $row ) {
    my $expires_at    = $self->support->column( $row, 'expires_at' );
    my $expires_epoch = $self->support->epoch_from_timestamp($expires_at);
    if ( !defined $expires_epoch ) {
        return 1;
    }

    return $expires_epoch <= $self->clock->now_epoch ? 1 : 0;
}

sub _lock_token_hash ( $self, $token_hash ) {
    my $dbh = $self->_schema_dbh;
    if ( !$dbh ) {
        my $undefined;
        return $undefined;
    }

    my $locked = $dbh->selectrow_array(
        'SELECT token_id FROM identity_tokens WHERE token_hash = ? FOR UPDATE',
        undef, $token_hash
    );

    return $locked;
}

sub _schema_dbh ($self) {
    my $storage = eval { return $self->schema->storage };
    if ( !$storage || !$storage->can('dbh') ) {
        my $undefined;
        return $undefined;
    }

    my $dbh = eval { return $storage->dbh };
    return $dbh;
}

sub _tokens ($self) {
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

Creates a typed identity token and returns the raw token once. A second
unused token for the same user and type rotates the existing row instead of
inserting another. A unique C<token_hash> collision remints the hash once
and does not return another user's token. A unique C<token_id> collision
remints the id once and does not return another user's token. A leftover
unique C<token_id> with this user and hash reuses the token.

=head2 consume_token

Locks, validates, and marks a token as used.

=head1 DIAGNOSTICS

Invalid, used, or expired tokens return C<invalid_token>, C<token_used>, or
C<token_expired>.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a DBIx::Class schema with an C<IdentityToken> resultset.

=head1 DEPENDENCIES

Uses L<GPForum::Infrastructure::UniqueConflict>,
L<GPForum::Service::Identity::Support>, and L<GPForum::Service::SessionToken>.

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
