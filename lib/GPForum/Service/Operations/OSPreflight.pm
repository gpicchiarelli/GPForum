# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::OSPreflight;

use Const::Fast;
use List::Util qw(any);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::OS::Preflight;
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;

our $VERSION = '0.001';

const my $MINIMUM_WORKERS      => 1;
const my $DEFAULT_MAX_OPEN_FDS => 65_536;

# The checks whose findings the host line and the open-files line stand
# for when they pass.
const my @PLATFORM_CHECKS => qw(os event_backend cpu_count);
const my @FILE_CHECKS =>
  qw(open_file_descriptors file_descriptor_limit file_descriptor_usage);

# The operating systems as their makers write them.
const my %SYSTEM_NAME => (
    linux   => 'Linux',
    freebsd => 'FreeBSD',
    darwin  => 'macOS',
);

# What fixes each problem, by the key of its sentence.
const my %FIX => (
    'preflight.workers_below' => ['preflight.fix_min_workers'],
    'preflight.web_over'      => ['preflight.fix_web_auto'],
    'preflight.open_over'     => ['preflight.fix_open_over'],
    'preflight.limit_low'     =>
      [qw(preflight.fix_nofile_unit preflight.fix_nofile_shell)],
    'preflight.usage_high' =>
      [qw(preflight.fix_nofile_unit preflight.fix_nofile_shell)],
    'preflight.swap_high'           => ['preflight.fix_swap'],
    'preflight.swap_elevated'       => ['preflight.fix_swap'],
    'preflight.feature_unsupported' => ['preflight.fix_feature'],
);

has runtime => undef;    # optional: without one the check fails, saying so
has host    => sub { return GPForum::Service::Operations::Host->new; };
has min_recommended_workers   => undef;    # optional: the runtime's
has max_open_file_descriptors => undef;    # optional: the runtime's

sub check ($self) {
    return _failed_runtime() if !$self->runtime;

    return GPForum::OS::Preflight->from_runtime( $self->runtime,
        $self->_settings, )->report;
}

# What an operator reads of a report: the host, the web processes and the
# open-file limit when they are fine, every check that is not, and under each
# problem what to change. The checks that pass and say nothing an operator
# acts on -- sockets, process classes, features left on auto -- stay in the
# JSON report.
sub findings ( $self, $report, $findings = undef ) {
    $findings //= GPForum::Service::Operations::Findings->new(
        catalog => $self->host->catalog );
    my %problem = map { $_->{name} => $_ }
      grep { $_->{status} ne 'ok' } @{ $report->{checks} // [] };
    my $os = $report->{os} // {};

    if ( !any { $problem{$_} } @PLATFORM_CHECKS ) {
        $findings->add(
            name    => 'host',
            status  => 'ok',
            message => $self->_counted(
                'preflight.host',
                {
                    os      => _system_name( $os->{name} ),
                    backend => $os->{event_backend},
                    cpus    => $os->{cpu_count},
                }
            ),
        );
    }
    my $processes = $report->{runtime}{web_processes};
    if (   !$problem{web_processes}
        && defined $processes
        && defined $os->{cpu_count} )
    {
        $findings->add(
            name    => 'web_processes',
            status  => 'ok',
            message => $self->_counted(
                'preflight.web_ok',
                { processes => $processes, cpus => $os->{cpu_count} }
            ),
        );
    }
    my $limit = ( $report->{resources} // {} )->{file_descriptor_limit};
    if ( defined $limit && !any { $problem{$_} } @FILE_CHECKS ) {
        $findings->add(
            name    => 'open_files',
            status  => 'ok',
            message => [ 'preflight.files_ok', { limit => $limit } ],
        );
    }

    for my $check ( grep { $_->{status} ne 'ok' } @{ $report->{checks} } ) {
        $findings->add(
            name    => $check->{name},
            status  => $check->{status},
            message => $self->_counted( $check->{key}, $check->{parameters} ),
            fixes   => $self->_fixes($check),
        );
    }

    return $findings;
}

# A sentence that counts CPUs has its own wording for one, where the
# catalogs carry it: "1 CPU", not "1 CPUs".
sub _counted ( $self, $key, $parameters ) {
    $parameters //= {};
    my $cpus = $parameters->{cpus};
    if (   defined $cpus
        && $cpus == 1
        && defined $self->host->catalog->template("${key}_one") )
    {
        return [ "${key}_one", $parameters ];
    }

    return [ $key, $parameters ];
}

sub _system_name ($name) {
    $name //= q{};

    return exists $SYSTEM_NAME{$name} ? $SYSTEM_NAME{$name} : $name;
}

sub _fixes ( $self, $check ) {
    my $key = $check->{key} // q{};
    return [] if !exists $FIX{$key};
    my $fix = $FIX{$key};

    my %parameters =
      ( %{ $check->{parameters} // {} }, where => $self->host->where, );

    return [ map { [ $_, \%parameters ] } @{$fix} ];
}

sub _settings ($self) {
    my %settings = %{ $self->runtime->os_preflight_settings || {} };
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

=head2 findings

Takes a report from L</check> and, optionally, a
L<GPForum::Service::Operations::Findings> to add to; returns the findings an
operator reads: the host, the web processes and the open-file limit when
they pass, and each check that does not, in the operator's language, with
the settings or commands that fix it.

=head2 host

The L<GPForum::Service::Operations::Host> whose settings file the fixes
name.

=head1 DIAGNOSTICS

None of its own. An exception from the runtime or from
L<GPForum::OS::Preflight> propagates.

=head1 CONFIGURATION AND ENVIRONMENT

None read directly. The thresholds come from the runtime's configuration
(C<os_preflight_settings>) unless set on the object.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<GPForum::OS::Preflight>,
L<GPForum::Service::Operations::Findings>,
L<GPForum::Service::Operations::Host>; the C<runtime>
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
