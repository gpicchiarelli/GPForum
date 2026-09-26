# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::Registration;

use strict;
use warnings;

use Const::Fast;
use Unicode::Normalize qw(NFC);
use Mojo::Base -base, -signatures;

use GPForum::Service::Password;

our $VERSION = '0.001';

const my $MINIMUM_USERNAME_LENGTH => 3;
const my $MAXIMUM_USERNAME_LENGTH => 32;
const my $MINIMUM_PASSWORD_LENGTH => 12;

has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has password_service => sub { return GPForum::Service::Password->new; };

sub prepare ( $self, $input ) {
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

sub _user_record ( $self, $values, $credential ) {
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

sub _password_credential ( $self, $values ) {
    return {
        type        => 'password',
        secret_hash =>
          $self->password_service->hash_password( $values->{password} ),
    };
}

sub _normalized_values ($input) {
    return {
        username         => _normalize_username( $input->{username} ),
        display_name     => _normalize_display_name( $input->{display_name} ),
        email_normalized => lc _trim( $input->{email} ),
        password => defined $input->{password} ? $input->{password} : q{},
    };
}

sub _validation_errors ($values) {
    my %errors;

    _set_error( \%errors, 'username',     _username_error($values) );
    _set_error( \%errors, 'display_name', _display_name_error($values) );
    _set_error( \%errors, 'email',        _email_error($values) );
    _set_error( \%errors, 'password',     _password_error($values) );

    return \%errors;
}

sub _set_error ( $errors, $field, $message ) {
    if ( defined $message && length $message ) {
        $errors->{$field} = $message;
    }

    return;
}

sub _username_error ($values) {
    if ( !length $values->{username} ) {
        return 'username is required';
    }

    return _username_shape_error($values);
}

sub _username_shape_error ($values) {
    if (
        !_length_between(
            $values->{username}, $MINIMUM_USERNAME_LENGTH,
            $MAXIMUM_USERNAME_LENGTH
        )
      )
    {
        return 'username length is invalid';
    }

    # ASCII, not [[:lower:]]. Under Unicode semantics that POSIX class matches
    # any lowercase letter in any script, so "\x{0430}dmin" (Cyrillic a),
    # "admi\x{0456}n" (Cyrillic i) and "\x{03BF}wner" (Greek omicron) were all
    # accepted as usernames -- distinct rows, visually identical to the
    # accounts they impersonate. The username is an identifier: it appears in
    # profile URLs, in mentions and in moderation records, and a reader has no
    # way to tell two of them apart. Display names stay Unicode, because a
    # person's name is not an identifier.
    ## no critic (RegularExpressions::ProhibitEnumeratedClasses)
    # The policy asks for [[:lower:]] here, and that is the defect: under
    # Unicode semantics it matches a lowercase letter in any script. The
    # enumeration is deliberate and the whole point.
    if ( $values->{username} !~ /\A [a-z] [a-z0-9_]+ \z/msx ) {
        return 'username format is invalid';
    }
    ## use critic

    my $undefined;
    return $undefined;
}

sub _display_name_error ($values) {
    return !length $values->{display_name} ? 'display name is required' : undef;
}

sub _email_error ($values) {
    if ( !length $values->{email_normalized} ) {
        return 'email is required';
    }
    if ( $values->{email_normalized} !~
        /\A [^@\s]+ [@] [^@\s]+ [.] [^@\s]+ \z/msx )
    {
        return 'email format is invalid';
    }

    my $undefined;
    return $undefined;
}

sub _password_error ($values) {
    return
      length $values->{password} < $MINIMUM_PASSWORD_LENGTH
      ? "password must be at least $MINIMUM_PASSWORD_LENGTH characters"
      : undef;
}

sub _length_between ( $value, $minimum, $maximum ) {
    return length $value >= $minimum && length $value <= $maximum ? 1 : 0;
}

sub _normalize_username ($value) {
    return lc _trim($value);
}

# Composed form, so "e" + U+0301 and U+00E9 are the same string rather than two
# spellings of the same name that compare unequal.
sub _normalize_display_name ($value) {
    return NFC( _trim($value) );
}

sub _trim ($value) {
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

Uses L<Const::Fast>, L<Mojo::Base>, L<GPForum::Infrastructure::Id>, and
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
