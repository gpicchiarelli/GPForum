# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Runtime;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::OS;

our $VERSION = '0.001';

const my $POLICY_CAP_TO_CPU => 'cap-to-cpu';

has web_processes         => 1;
has worker_processes      => 1;
has realtime_processes    => 1;
has os_profile            => sub { return GPForum::OS->detect; };
has os_feature_settings   => sub { return {}; };
has os_preflight_settings => sub { return {}; };
has worker_policy         => $POLICY_CAP_TO_CPU;
has max_web_per_cpu       => 2;

sub from_config ( $class, $config ) {
    return $class->new(
        web_processes         => $config->web_processes,
        worker_processes      => $config->worker_processes,
        realtime_processes    => $config->realtime_processes,
        os_profile            => GPForum::OS->detect,
        os_feature_settings   => $config->os_feature_settings,
        os_preflight_settings => $config->os_preflight_settings,
        worker_policy         => $config->runtime_worker_policy,
        max_web_per_cpu       => $config->runtime_max_web_per_cpu,
    );
}

# The web processes Hypnotoad is given: under cap-to-cpu, no more than the
# CPUs can carry; under configured, what was asked for.
sub effective_web_processes ($self) {
    return $self->capped_web_processes(
        $self->web_processes,   $self->os_profile->cpu_count,
        $self->max_web_per_cpu, $self->worker_policy,
    );
}

# The rule itself, for a caller that holds the numbers rather than a runtime:
# GPForum::OS::RuntimePolicy configures Hypnotoad with it, and
# GPForum::OS::Preflight checks the same number.
sub capped_web_processes ( $class, $configured, $cpu_count, $per_cpu, $policy )
{
    return $configured if !defined $configured;
    return $configured if $policy ne $POLICY_CAP_TO_CPU;

    my $cap = $cpu_count * $per_cpu;
    return $configured <= $cap ? $configured : $cap;
}

sub as_hash ($self) {
    return {
        web_processes      => $self->web_processes,
        worker_processes   => $self->worker_processes,
        realtime_processes => $self->realtime_processes,
        os                 => $self->os_profile->snapshot,
        os_features        =>
          $self->os_profile->feature_snapshot( $self->os_feature_settings ),
        os_sockets =>
          $self->os_profile->socket_snapshot( $self->os_feature_settings ),
        os_processes =>
          $self->os_profile->process_snapshot( $self->os_feature_settings ),
        os_preflight_settings => $self->os_preflight_settings,
        worker_policy         => $self->worker_policy,
        max_web_per_cpu       => $self->max_web_per_cpu,
    };
}

1;

__END__

=head1 NAME

GPForum::Runtime - Runtime process profile.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $runtime = GPForum::Runtime->from_config($config);

=head1 DESCRIPTION

Carries process-count settings for the GPForum multi-process runtime model.

=head1 SUBROUTINES/METHODS

=head2 from_config

Creates a runtime profile from configuration.

=head2 as_hash

Returns the profile as a plain hash reference.

=head2 effective_web_processes

Returns the web processes Hypnotoad is given: under the C<cap-to-cpu> worker
policy no more than the CPU count times C<max_web_per_cpu>, under
C<configured> the configured count.

=head2 capped_web_processes

Class method. Takes the configured web processes, the CPU count, the web
processes allowed per CPU and the worker policy, and returns the count
L</effective_web_processes> describes.

=head1 DIAGNOSTICS

This module does not throw its own exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

Receives validated process counts, the worker policy
(C<GPFORUM_RUNTIME_WORKER_POLICY>) and the web processes allowed per CPU
(C<GPFORUM_RUNTIME_MAX_WEB_PER_CPU>) from L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

This profile is descriptive; process supervision is implemented outside this
module.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
