# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ScheduledJobsApp;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# The application as bin/gpforum-scheduled-jobs builds it, reduced to what the
# command asks of it: a controller -- this object again -- whose
# gp_scheduled_jobs is the runner given and whose gp_attachment_storage is the
# storage given. It counts the controllers built, so a test can tell whether
# the command built the application at all.
has attachment_storage => undef;    # optional: a storage the command may lend
has controllers_built  => 0;
has jobs => undef;    # optional: the runner gp_scheduled_jobs answers

sub build_controller ($self) {
    $self->controllers_built( $self->controllers_built + 1 );

    return $self;
}

sub gp_scheduled_jobs ($self) {
    return $self->jobs;
}

sub gp_attachment_storage ($self) {
    return $self->attachment_storage;
}

1;

__END__

=head1 NAME

GPForum::Test::ScheduledJobsApp - The application scheduled-jobs builds, reduced.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $app = GPForum::Test::ScheduledJobsApp->new(
        jobs               => GPForum::Test::ScheduledJobsRunner->new,
        attachment_storage => $storage,
    );
    GPForum::Command::ScheduledJobs->new( app => sub { $app } )->run('--once');

=head1 DESCRIPTION

Stands in for the application L<GPForum::Command::ScheduledJobs> builds when
no runner is passed to it, and for the controller that application builds.

=head1 SUBROUTINES/METHODS

=head2 build_controller

Counts the call in C<controllers_built> and returns the object itself.

=head2 gp_scheduled_jobs

Returns C<jobs>.

=head2 gp_attachment_storage

Returns C<attachment_storage>.

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
