# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::OSPreflight;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::OS::Preflight;

our $VERSION = '0.001';

const my $MINIMUM_WORKERS      => 1;
const my $DEFAULT_MAX_OPEN_FDS => 65_536;

has runtime                   => undef;
has min_recommended_workers   => undef;
has max_open_file_descriptors => undef;

sub check ($self) {
    return _failed_runtime() if !$self->runtime;

    return GPForum::OS::Preflight->from_runtime( $self->runtime,
        $self->_settings, )->report;
}

sub _settings ($self) {
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

sub _runtime_settings ($runtime) {
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

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $report = GPForum::Service::Operations::OSPreflight->new(
        runtime                   => $runtime,
        min_recommended_workers   => 2,
        max_open_file_descriptors => 65_536,
    )->check;
    print "$report->{status}\n";    # ok, degraded or fail

=head1 DESCRIPTION

Delegates OS posture validation to L<GPForum::OS::Preflight> while preserving
the operations service boundary used by readiness, metrics, and platform
checks.

The two thresholds it passes on are taken, in order, from this object's
attributes, from the runtime's C<os_preflight_settings>, and otherwise from
the defaults: one recommended worker and 65 536 open file descriptors.

=head1 SUBROUTINES/METHODS

=head2 check

Takes no arguments. Returns the C<report> of L<GPForum::OS::Preflight>
for C<runtime>: a hash reference with C<status> (C<ok>, C<degraded> or
C<fail>), C<checks>, and the C<os>, C<runtime>, C<resources>,
C<recommendations>, C<features>, C<sockets> and C<processes> it judged.
Without a C<runtime> it inspects nothing and returns C<status> C<fail>
with a single check, C<runtime>, failed for the reason
C<runtime unavailable>.

=head1 DIAGNOSTICS

None of its own. An exception from the runtime or from
L<GPForum::OS::Preflight> propagates.

=head1 CONFIGURATION AND ENVIRONMENT

None read directly. The thresholds come from the runtime's configuration
(C<os_preflight_settings>) unless set on the object.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<GPForum::OS::Preflight>; the C<runtime>
is a L<GPForum::Runtime>.

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
