package GPForum::Test::AccountStoreServices;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has actions        => sub { return []; };
has consumed       => sub { return []; };
has created_tokens => sub { return []; };
has credentials    => sub { return {}; };
has mail_jobs      => sub { return []; };
has revokes        => sub { return []; };
has rotations      => sub { return []; };

sub hash_password {
    my ( undef, $password ) = @_;

    return 'hashed:' . $password;
}

sub verify_password {
    my ( undef, $password, $hash ) = @_;

    if ( !defined $password || !defined $hash ) {
        return 0;
    }

    return $hash eq ( 'hashed:' . $password ) ? 1 : 0;
}

sub active_password_credential {
    my ( $self, $user_id ) = @_;

    return $self->credentials->{$user_id};
}

sub rotate_password_credential {
    my ( $self, $input ) = @_;

    $self->credentials->{ $input->{user_id} } = {
        secret_hash => $input->{secret_hash},
        user_id     => $input->{user_id},
    };
    push @{ $self->rotations }, $input;

    return 1;
}

sub create_token {
    my ( $self, $input ) = @_;

    push @{ $self->created_tokens }, $input;

    return {
        ok        => 1,
        raw_token => 'raw-1',
        token_id  => 'tok-1',
    };
}

sub consume_token {
    my ( $self, $type, $raw ) = @_;

    push @{ $self->consumed }, { raw => $raw, type => $type };

    return $self->_consume_result($raw);
}

sub revoke_user_sessions {
    my ( $self, $user_id, $now ) = @_;

    push @{ $self->revokes }, { now => $now, user_id => $user_id };

    return;
}

sub record_action {
    my ( $self, $input ) = @_;

    push @{ $self->actions }, $input;

    return;
}

sub record_mail {
    my ( $self, $input ) = @_;

    push @{ $self->mail_jobs }, $input;

    return;
}

sub _consume_result {
    my ( $self, $raw ) = @_;

    my $known = $self->_known_consume($raw);
    if ($known) {
        return $known;
    }

    return {
        email_normalized => 'new@example.test',
        ok               => 1,
        token_id         => 'tok-1',
        user_id          => 'user-1',
    };
}

sub _known_consume {
    my ( $self, $raw ) = @_;

    my $failure = $self->_failed_consume($raw);
    if ($failure) {
        return $failure;
    }

    return $self->_special_consume($raw);
}

sub _failed_consume {
    my ( undef, $raw ) = @_;

    if ( $raw eq 'bad' ) {
        return { error => 'invalid_token', ok => 0 };
    }
    if ( $raw eq 'used' ) {
        return { error => 'token_used', ok => 0 };
    }

    return;
}

sub _special_consume {
    my ( undef, $raw ) = @_;

    if ( $raw eq 'empty-email' ) {
        return {
            email_normalized => undef,
            ok               => 1,
            token_id         => 'tok-1',
            user_id          => 'user-1',
        };
    }
    if ( $raw eq 'missing-user' ) {
        return {
            email_normalized => 'new@example.test',
            ok               => 1,
            token_id         => 'tok-1',
            user_id          => 'gone',
        };
    }
    if ( $raw eq 'taken-email' ) {
        return {
            email_normalized => 'other@example.test',
            ok               => 1,
            token_id         => 'tok-taken',
            user_id          => 'user-1',
        };
    }
    if ( $raw eq 'verify-pending' ) {
        return {
            email_normalized => 'pending@example.test',
            ok               => 1,
            token_id         => 'tok-v',
            user_id          => 'user-pending',
        };
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Test::AccountStoreServices - Identity account-store fakes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $services = GPForum::Test::AccountStoreServices->new;

=head1 DESCRIPTION

Test double for password hashing, credential rotation, token issue/consume,
session revocation, and audit recording used by C<Identity::AccountStore>.

=head1 SUBROUTINES/METHODS

=head2 hash_password

Returns a deterministic fake hash.

=head2 verify_password

Compares a password against the deterministic fake hash.

=head2 active_password_credential

Returns the stored credential for a user id.

=head2 rotate_password_credential

Replaces the stored credential and records the rotation.

=head2 create_token

Records token commands and returns a fixed token id.

=head2 consume_token

Maps known raw tokens to invalid, used, empty-email, missing-user,
taken-email, or success.

=head2 revoke_user_sessions

Records session revocation commands.

=head2 record_action

Records audit commands.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not emulate SQL token locking.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
