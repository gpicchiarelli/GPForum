# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ScheduledJobsRunner;

use Carp qw(croak);
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# The scheduled-jobs runner as bin/gpforum-scheduled-jobs sees it: one pass
# that answers with a fixed summary, or dies as a runner whose database is
# gone would. It keeps the options each pass was given, and can hold the
# attachment store the command lends the application's attachment storage to.
has attachment_store =>
  undef;    # optional: only the storage-lending tests give one
has failure => undef;                       # optional: runs succeed without one
has runs    => sub { return []; };
has summary => sub { return { ok => 1 }; };

sub run {
    my ( $self, $options ) = @_;

    push @{ $self->runs }, $options;
    croak $self->failure if defined $self->failure;

    return $self->summary;
}

1;

__END__

=head1 NAME

GPForum::Test::ScheduledJobsRunner - A scheduled-jobs runner with a fixed answer.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    GPForum::Command::ScheduledJobs->new(
        jobs => GPForum::Test::ScheduledJobsRunner->new( summary => {...} ) );

=head1 DESCRIPTION

Stands in for L<GPForum::Service::Operations::ScheduledJobs> where a test
needs only what the command prints.

=head1 SUBROUTINES/METHODS

=head2 run

Records the options it was given in C<runs>, then returns the summary, or
croaks with C<failure> when one is set.

=head1 DIAGNOSTICS

None.

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
