package GPForum::Service::Identity::Registration;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Password;

our $VERSION = '0.001';

const my $MINIMUM_USERNAME_LENGTH => 3;
const my $MAXIMUM_USERNAME_LENGTH => 32;
const my $MINIMUM_PASSWORD_LENGTH => 12;

has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has password_service => sub { return GPForum::Service::Password->new; };

sub prepare {
    my ( $self, $input ) = @_;

    my $values = _normalized_values($input);
    my $errors = _validation_errors($values);

    if ( keys %{$errors} ) {
        return { ok => 0, errors => $errors, values => $values };
    }

    my $credential = $self->_password_credential($values);

    return {
        ok           => 1,
        registration => {
            user       => $self->_user_record( $values, $credential ),
            credential => $credential,
            audit      => { event_type => 'user.registered' },
        },
    };
}

sub _user_record {
    my ( $self, $values, $credential ) = @_;

    return {
        id                => $self->id_service->uuid,
        username          => $values->{username},
        display_name      => $values->{display_name},
        email_normalized  => $values->{email_normalized},
        password_hash     => $credential->{secret_hash},
        status            => 'pending',
        trust_level       => 0,
        email_verified_at => undef,
    };
}

sub _password_credential {
    my ( $self, $values ) = @_;

    return {
        type        => 'password',
        secret_hash =>
          $self->password_service->hash_password( $values->{password} ),
    };
}

sub _normalized_values {
    my ($input) = @_;

    return {
        username         => _normalize_username( $input->{username} ),
        display_name     => _trim( $input->{display_name} ),
        email_normalized => lc _trim( $input->{email} ),
        password => defined $input->{password} ? $input->{password} : q{},
    };
}

sub _validation_errors {
    my ($values) = @_;

    my %errors;

    _set_error( \%errors, 'username',     _username_error($values) );
    _set_error( \%errors, 'display_name', _display_name_error($values) );
    _set_error( \%errors, 'email',        _email_error($values) );
    _set_error( \%errors, 'password',     _password_error($values) );

    return \%errors;
}

sub _set_error {
    my ( $errors, $field, $message ) = @_;

    if ( defined $message && length $message ) {
        $errors->{$field} = $message;
    }

    return;
}

sub _username_error {
    my ($values) = @_;

    if ( !length $values->{username} ) {
        return 'username is required';
    }

    return _username_shape_error($values);
}

sub _username_shape_error {
    my ($values) = @_;

    if (
        !_length_between(
            $values->{username}, $MINIMUM_USERNAME_LENGTH,
            $MAXIMUM_USERNAME_LENGTH
        )
      )
    {
        return 'username length is invalid';
    }
    if ( $values->{username} !~ /\A [[:lower:]] [[:lower:][:digit:]_]+ \z/msx )
    {
        return 'username format is invalid';
    }

    return;
}

sub _display_name_error {
    my ($values) = @_;

    return !length $values->{display_name} ? 'display name is required' : undef;
}

sub _email_error {
    my ($values) = @_;

    if ( !length $values->{email_normalized} ) {
        return 'email is required';
    }
    if ( $values->{email_normalized} !~
        /\A [^@\s]+ [@] [^@\s]+ [.] [^@\s]+ \z/msx )
    {
        return 'email format is invalid';
    }

    return;
}

sub _password_error {
    my ($values) = @_;

    return
      length $values->{password} < $MINIMUM_PASSWORD_LENGTH
      ? "password must be at least $MINIMUM_PASSWORD_LENGTH characters"
      : undef;
}

sub _length_between {
    my ( $value, $minimum, $maximum ) = @_;

    return length $value >= $minimum && length $value <= $maximum ? 1 : 0;
}

sub _normalize_username {
    my ($value) = @_;

    return lc _trim($value);
}

sub _trim {
    my ($value) = @_;

    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::Registration - Registration preparation service.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = GPForum::Service::Identity::Registration->new->prepare(\%input);

=head1 DESCRIPTION

Validates and normalizes registration input, prepares user and credential
records, and keeps registration workflow logic out of controllers and ORM
classes.

=head1 SUBROUTINES/METHODS

=head2 prepare

Returns either validation errors or normalized user, credential, and audit
records ready for persistence.

=head1 DIAGNOSTICS

Password hashing failures are reported by L<GPForum::Service::Password>.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, L<GPForum::Service::Id>, and
L<GPForum::Service::Password>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

This service prepares records; database persistence is added in the next
identity increment.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
