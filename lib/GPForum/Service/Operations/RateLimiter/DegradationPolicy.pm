# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::RateLimiter::DegradationPolicy;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $MODE_FAIL_CLOSED => 'fail_closed';
const my $MODE_PERMISSIVE  => 'permissive';
const my %VALID_MODE => map { $_ => 1 } ( $MODE_FAIL_CLOSED, $MODE_PERMISSIVE );
const my %PERMISSIVE_ENVIRONMENT => map { $_ => 1 } qw(development test);
const my $CONFIG_ACCESSOR        => 'rate_limit_degradation_mode';

has mode => sub { return $MODE_FAIL_CLOSED; };

sub new ( $class, @arguments ) {
    my $self = $class->SUPER::new(@arguments);
    _assert_mode( $self->mode );

    return $self;
}

sub fail_closed_mode { return $MODE_FAIL_CLOSED; }

sub permissive_mode { return $MODE_PERMISSIVE; }

sub from_environment ( $class, $environment ) {
    my $name = defined $environment ? $environment : q{};

    return $class->new(
        mode => exists $PERMISSIVE_ENVIRONMENT{$name}
        ? $MODE_PERMISSIVE
        : $MODE_FAIL_CLOSED
    );
}

sub from_config ( $class, $config ) {
    return $class->new if !$config;

    my $configured = _configured_mode($config);
    return $class->new( mode => $configured ) if defined $configured;

    return $class->from_environment( $config->environment );
}

sub fail_closed ($self) {
    return $self->mode eq $MODE_FAIL_CLOSED ? 1 : 0;
}

sub permissive ($self) {
    return $self->mode eq $MODE_PERMISSIVE ? 1 : 0;
}

sub _configured_mode ($config) {
    my $undefined;
    return $undefined if !$config->can($CONFIG_ACCESSOR);

    my $mode = $config->$CONFIG_ACCESSOR;
    return $undefined if !defined $mode || $mode eq q{};

    return $mode;
}

sub _assert_mode ($mode) {
    my $name = defined $mode ? $mode : q{};
    if ( !exists $VALID_MODE{$name} ) {
        croak 'unknown rate limiter degradation mode: ' . $name;
    }

    return $name;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::RateLimiter::DegradationPolicy - Rate limiter
behaviour when the authoritative store is unavailable.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $policy =
      GPForum::Service::Operations::RateLimiter::DegradationPolicy
      ->from_config($config);

    if ( $policy->fail_closed ) {
        ...
    }

=head1 DESCRIPTION

The rate limiter keeps its authoritative counters in PostgreSQL so that every
Hypnotoad worker shares one bucket. When that store throws, the limiter has to
choose between two incompatible failure modes, and this object makes that
choice explicit, inspectable, and testable.

=over

=item C<permissive>

Fall back to the per-process L<GPForum::Service::Operations::RateLimiter::LocalMemoryStore>
and keep serving. Every decision is flagged C<< degraded => 1 >>. This is only
correct for development, where a single process serves all traffic.

=item C<fail_closed>

Deny the request. The limiter does not touch the local memory store at all, so
no per-process counter can be mistaken for cluster state. The denial carries
C<< denied_reason => 'store_unavailable' >> to separate it from an ordinary
over-limit denial.

=back

C<fail_closed> is the default. A caller that wants the permissive behaviour has
to ask for it.

=head1 SUBROUTINES/METHODS

=head2 new

Builds the policy and croaks when C<mode> is not one of C<fail_closed> or
C<permissive>. An invalid mode fails at wiring time rather than on the first
throwing request.

=head2 fail_closed_mode

Class constant for the C<fail_closed> mode name.

=head2 permissive_mode

Class constant for the C<permissive> mode name.

=head2 from_environment

Derives the mode from a GPForum environment name. C<development> and C<test>
are permissive; every other environment, including C<staging> and the
C<production> profiles, is fail-closed. An undefined or unknown environment is
fail-closed.

=head2 from_config

Derives the mode from a L<GPForum::Config> object. When the configuration
object exposes a C<rate_limit_degradation_mode> accessor its value wins;
otherwise the mode comes from C<< $config->environment >>. A missing
configuration object yields the fail-closed default.

=head2 fail_closed

True when the limiter must deny requests it cannot authoritatively count.

=head2 permissive

True when the limiter may fall back to per-process counters.

=head1 DIAGNOSTICS

C<unknown rate limiter degradation mode: %s> is thrown by L</new> for any mode
outside the two supported names.

=head1 CONFIGURATION AND ENVIRONMENT

Reads only C<< $config->environment >>, plus an optional
C<rate_limit_degradation_mode> accessor if L<GPForum::Config> ever grows one.
No environment variables are read directly.

=head1 DEPENDENCIES

Core Perl plus L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The environment mapping is a list of permissive environment names, so a new
development-shaped environment defaults to fail-closed until it is added here.
That direction is deliberate.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
