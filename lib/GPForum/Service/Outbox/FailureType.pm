package GPForum::Service::Outbox::FailureType;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $TRANSIENT => 'transient';
const my @RULES => (
    [ 'serialization', qr/Serial/imsx, qr/serial/imsx ],
    [
        'authorization', qr/Authorization|Authorisation/imsx,
        qr/forbidden|unauthor/imsx
    ],
    [ 'transport', qr/Transport|Notify|Pg/imsx, qr/transport|notify/imsx ],
    [ 'permanent', qr/Permanent/imsx,           qr/permanent/imsx ],
);

sub classify {
    my ( $self, $exception ) = @_;

    my $declared = $self->declared($exception);
    if ( defined $declared ) {
        return $declared;
    }

    return $self->matched($exception);
}

sub declared {
    my ( undef, $exception ) = @_;

    if ( !ref $exception ) {
        return;
    }
    if ( !$exception->can('failure_type') ) {
        return;
    }

    return $exception->failure_type;
}

sub matched {
    my ( $self, $exception ) = @_;

    my $class = ref $exception || q{};
    my $text  = "$exception";
    for my $rule (@RULES) {
        if ( $self->matches( $class, $text, $rule ) ) {
            return $rule->[0];
        }
    }

    return $TRANSIENT;
}

sub matches {
    my ( undef, $class, $text, $rule ) = @_;

    if ( $class =~ $rule->[1] ) {
        return 1;
    }
    if ( $text =~ $rule->[2] ) {
        return 1;
    }

    return 0;
}

1;

__END__

=head1 NAME

GPForum::Service::Outbox::FailureType - Outbox failure classification.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $type = $classifier->classify($exception);

=head1 DESCRIPTION

Maps transport exceptions to C<serialization>, C<authorization>,
C<transport>, C<permanent>, or C<transient>. Declared C<failure_type>
methods win over class and message regexes.
L<GPForum::Service::Outbox::Dispatcher> still retries, locks, and
dead-letters.

=head1 SUBROUTINES/METHODS

=head2 classify

Returns the canonical failure type for an exception.

=head2 declared

Returns a C<failure_type> method value when present.

=head2 matched

Applies class and message regex rules.

=head2 matches

True when a rule's class or text regex matches.

=head1 DIAGNOSTICS

Unknown exceptions classify as C<transient>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Regex rules are operational categories, not a full error taxonomy.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
