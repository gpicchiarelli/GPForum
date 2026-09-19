package GPForum::Service::Operations::OSPreflight;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::OS::Preflight;

our $VERSION = '0.001';

const my $MINIMUM_WORKERS      => 1;
const my $DEFAULT_MAX_OPEN_FDS => 65_536;

has runtime                   => undef;
has min_recommended_workers   => undef;
has max_open_file_descriptors => undef;

sub check {
    my ($self) = @_;

    return _failed_runtime() if !$self->runtime;

    return GPForum::OS::Preflight->from_runtime( $self->runtime,
        $self->_settings, )->report;
}

sub _settings {
    my ($self) = @_;

    my %settings = _runtime_settings( $self->runtime );
    if ( defined $self->min_recommended_workers ) {
        $settings{min_recommended_workers} = $self->min_recommended_workers;
    }
    if ( defined $self->max_open_file_descriptors ) {
        $settings{max_open_file_descriptors} = $self->max_open_file_descriptors;
    }

    $settings{min_recommended_workers}   //= $MINIMUM_WORKERS;
    $settings{max_open_file_descriptors} //= $DEFAULT_MAX_OPEN_FDS;

    return %settings;
}

sub _runtime_settings {
    my ($runtime) = @_;

    return () if !$runtime || !$runtime->can('os_preflight_settings');

    my $settings = $runtime->os_preflight_settings || {};
    return %{$settings};
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
