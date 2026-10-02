# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::DeadLetterReplayer;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

# The dead-letter replay service as bin/gpforum-dead-letter-replay sees it:
# each call answers with the next outcome in turn, and an outcome that is a
# plain string dies with it, as a replay whose database went away would.
has outcomes => sub { return []; };

sub replay {
    my ($self) = @_;

    my $outcome = shift @{ $self->outcomes };
    croak 'no outcome left to replay' if !defined $outcome;
    croak $outcome                    if !ref $outcome;

    return $outcome;
}

1;

__END__

=head1 NAME

GPForum::Test::DeadLetterReplayer - A dead-letter replay with scripted outcomes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    GPForum::Command::DeadLetterReplay->new(
        replayer => GPForum::Test::DeadLetterReplayer->new(
            outcomes => [ { status => 'replayed', ... }, 'database gone' ]
        )
    );

=head1 DESCRIPTION

Stands in for L<GPForum::Service::Outbox::DeadLetterReplay> where a test
needs only what the command prints.

=head1 SUBROUTINES/METHODS

=head2 replay

Returns the next outcome, or croaks with it when it is a string.

=head1 DIAGNOSTICS

Croaks when no outcome is left.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
