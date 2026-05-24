package GPForum::Service::Operations::OSPreflight;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::OS::Preflight;

our $VERSION = '0.001';

const my $MINIMUM_WORKERS      => 1;
const my $DEFAULT_MAX_OPEN_FDS => 1024;

has runtime                   => undef;
has min_recommended_workers   => $MINIMUM_WORKERS;
has max_open_file_descriptors => $DEFAULT_MAX_OPEN_FDS;

sub check {
    my ($self) = @_;

    return _failed_runtime() if !$self->runtime;

    return GPForum::OS::Preflight->from_runtime(
        $self->runtime,
        min_recommended_workers   => $self->min_recommended_workers,
        max_open_file_descriptors => $self->max_open_file_descriptors,
    )->report;
}

sub _failed_runtime {
    return {
        status => 'fail',
        checks => [
            {
                name   => 'runtime',
                status => 'fail',
                reason => 'runtime unavailable',
            },
        ],
    };
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::OSPreflight - Operations service wrapper for OS preflight.

=head1 DESCRIPTION

Delegates OS posture validation to L<GPForum::OS::Preflight> while preserving
the operations service boundary used by readiness, metrics, and platform
checks.

=cut
