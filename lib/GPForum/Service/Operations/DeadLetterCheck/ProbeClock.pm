# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DeadLetterCheck::ProbeClock;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

const my $NOW   => '2026-09-21T12:00:00Z';
const my $LATER => '2026-09-21T12:01:00Z';

sub now_iso8601 ($self) {
    return $NOW;
}

sub epoch_plus_iso8601 ( $self, $seconds ) {
    return $seconds ? $LATER : $NOW;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DeadLetterCheck::ProbeClock - The dead-letter check's clock, stopped at a fixed time.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # Built by GPForum::Service::Operations::DeadLetterCheck for its
    # simulate mode; nothing else uses it.
    my $probe = GPForum::Service::Operations::DeadLetterCheck::ProbeClock->new;

=head1 DESCRIPTION

Always C<2026-09-21T12:00:00Z>, so a run's evidence does not change with the hour. One of the in-memory stand-ins
L<GPForum::Service::Operations::DeadLetterCheck> runs the real
L<GPForum::Service::Outbox::Dispatcher> against in its C<simulate> mode.

=head1 SUBROUTINES/METHODS

=head2 now_iso8601

Returns the fixed time C<2026-09-21T12:00:00Z>.

=head2 epoch_plus_iso8601

Returns C<2026-09-21T12:01:00Z> for any non-zero number of seconds, and the fixed time otherwise.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

It stands in for PostgreSQL only as far as the dead-letter check needs.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
