package GPForum::Infrastructure::UniqueConflict;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $PG_UNIQUE => '23505';

sub is_conflict {
    my ( undef, $error ) = @_;

    if ( !_has_text($error) ) {
        return 0;
    }

    return _matches_unique($error);
}

sub throw {
    my ( undef, $constraint ) = @_;

    croak _message($constraint);
}

sub _matches_unique {
    my ($error) = @_;

    if ( $error =~ m/$PG_UNIQUE/msx ) {
        return 1;
    }
    if ( $error =~ m/unique [ ] constraint/imsx ) {
        return 1;
    }
    if ( $error =~ m/duplicate [ ] key/imsx ) {
        return 1;
    }

    return 0;
}

sub _message {
    my ($constraint) = @_;

    my $name = $constraint;
    if ( !_has_text($name) ) {
        $name = 'unknown';
    }

    return
"duplicate key value violates unique constraint \"$name\" ($PG_UNIQUE)";
}

sub _has_text {
    my ($value) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Infrastructure::UniqueConflict - Detect PostgreSQL unique races.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    if ( GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        return $existing;
    }

=head1 DESCRIPTION

Recognizes PostgreSQL C<23505> unique violations and the equivalent fake-store
messages used in tests. Stores catch the conflict and reload the winning row
instead of returning a 500.

=head1 SUBROUTINES/METHODS

=head2 is_conflict

True when the error text is a unique constraint violation.

=head2 throw

Raises a unique-violation error for test fakes.

=head1 DIAGNOSTICS

C<throw> croaks with a PostgreSQL-shaped unique violation string.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Carp>, L<Const::Fast>, and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Detection is string-based so non-PostgreSQL drivers must raise a matching
error text.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
