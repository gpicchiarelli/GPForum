# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::Registration;

use Const::Fast;
use Unicode::Normalize qw(NFC);
use Mojo::Base -base, -signatures;
use v5.40;

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

# The display name is composed, so "e" + U+0301 and U+00E9 are the same
# string rather than two spellings of the same name that compare unequal.
sub prepare ( $self, $input ) {
    my $values = {
        username         => lc _trim( $input->{username} ),
        display_name     => NFC( _trim( $input->{display_name} ) ),
        email_normalized => lc _trim( $input->{email} ),
        password         => $input->{password} // q{},
    };
    my $errors = _validation_errors($values);
    if ( keys %{$errors} ) {
        return { ok => 0, errors => $errors, values => $values };
    }

    my $credential = {
        type        => 'password',
        secret_hash =>
          $self->password_service->hash_password( $values->{password} ),
    };

    return {
        ok           => 1,
        registration => {
            user => {
                id                => $self->id_service->uuid,
                username          => $values->{username},
                display_name      => $values->{display_name},
                email_normalized  => $values->{email_normalized},
                password_hash     => $credential->{secret_hash},
                status            => 'pending',
                trust_level       => 0,
                email_verified_at => undef,
            },
            credential => $credential,
            audit      => { event_type => 'user.registered' },
        },
    };
}

# Each field's first problem, by field.
sub _validation_errors ($values) {
    my %errors;
    my $username = $values->{username};

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
    if ( !length $username ) {
        $errors{username} = 'username is required';
    }
    elsif (length $username < $MINIMUM_USERNAME_LENGTH
        || length $username > $MAXIMUM_USERNAME_LENGTH )
    {
        $errors{username} = 'username length is invalid';
    }
    elsif ( $username !~ /\A [a-z] [a-z0-9_]+ \z/msx ) {
        $errors{username} = 'username format is invalid';
    }
    ## use critic

    if ( !length $values->{display_name} ) {
        $errors{display_name} = 'display name is required';
    }
    if ( !length $values->{email_normalized} ) {
        $errors{email} = 'email is required';
    }
    elsif ( $values->{email_normalized} !~
        /\A [^@\s]+ [@] [^@\s]+ [.] [^@\s]+ \z/msx )
    {
        $errors{email} = 'email format is invalid';
    }
    if ( length $values->{password} < $MINIMUM_PASSWORD_LENGTH ) {
        $errors{password} =
          "password must be at least $MINIMUM_PASSWORD_LENGTH characters";
    }

    return \%errors;
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
