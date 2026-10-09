# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::Profile;

use Const::Fast;
use List::Util qw(min);
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

const my $PROFILE_VERSION    => 1;
const my $DEVELOPMENT_SECRET => 'gpforum-development-secret-change-me';
const my %ENV_TO_PROFILE => (
    development         => 'development',
    test                => 'development',
    staging             => 'staging',
    production          => 'production-small',
    'production-small'  => 'production-small',
    'production-medium' => 'production-medium',
);
const my %PROFILES => (
    development => {
        category_cache_ttl_seconds      => 15,
        event_retention_days            => 30,
        local_cache_max_entries         => 256,
        log_level                       => 'debug',
        name                            => 'development',
        notification_retention_days     => 14,
        partition_horizon_months        => 1,
        realtime_processes              => 1,
        requires_glifistore             => 0,
        requires_rotated_session_secret => 0,
        restore_evidence_required       => 0,
        version                         => $PROFILE_VERSION,
        web_processes                   => 1,
        worker_processes                => 1,
    },
    staging => {
        category_cache_ttl_seconds      => 30,
        event_retention_days            => 90,
        local_cache_max_entries         => 512,
        log_level                       => 'info',
        name                            => 'staging',
        notification_retention_days     => 30,
        partition_horizon_months        => 2,
        realtime_processes              => 1,
        requires_glifistore             => 0,
        requires_rotated_session_secret => 1,
        restore_evidence_required       => 1,
        version                         => $PROFILE_VERSION,
        web_processes                   => 2,
        worker_processes                => 1,
    },
    'production-small' => {
        category_cache_ttl_seconds      => 60,
        event_retention_days            => 365,
        local_cache_max_entries         => 2_048,
        log_level                       => 'info',
        name                            => 'production-small',
        notification_retention_days     => 90,
        partition_horizon_months        => 3,
        realtime_processes              => 1,
        requires_glifistore             => 0,
        requires_rotated_session_secret => 1,
        restore_evidence_required       => 1,
        version                         => $PROFILE_VERSION,
        web_processes                   => 4,
        worker_processes                => 2,
    },
    'production-medium' => {
        category_cache_ttl_seconds      => 60,
        event_retention_days            => 730,
        local_cache_max_entries         => 4_096,
        log_level                       => 'info',
        name                            => 'production-medium',
        notification_retention_days     => 180,
        partition_horizon_months        => 6,
        realtime_processes              => 2,
        requires_glifistore             => 0,
        requires_rotated_session_secret => 1,
        restore_evidence_required       => 1,
        version                         => $PROFILE_VERSION,
        web_processes                   => 8,
        worker_processes                => 4,
    },
);

sub names {
    return [ sort keys %PROFILES ];
}

sub name_for_environment ( $, $environment ) {
    my $key = $environment || q{};
    if ( !exists $ENV_TO_PROFILE{$key} ) {
        return undef;
    }

    return $ENV_TO_PROFILE{$key};
}

sub get ( $, $name ) {
    if ( !$name || !exists $PROFILES{$name} ) {
        return undef;
    }

    return { %{ $PROFILES{$name} } };
}

sub evaluate ( $self, $config ) {
    my $name    = $self->name_for_environment( $config->environment );
    my $profile = $self->get($name);
    if ( !$profile ) {
        return {
            errors  => { environment => 'unknown operational profile' },
            ok      => 0,
            profile => undef,
        };
    }

    return $self->_compare( $profile, $config );
}

sub _compare ( $self, $profile, $config ) {
    my $errors = {};
    $self->_require_floor(
        $errors,
        {
            actual => $config->web_processes,
            field  => 'web_processes',
            floor  => _web_floor( $profile, $config ),
        }
    );

    # The worker and realtime counts are not held to the profile's floors:
    # nothing starts processes from GPFORUM_WORKER_PROCESSES or
    # GPFORUM_REALTIME_PROCESSES, which are retired. Held to them, a
    # production-medium host failed readiness unless it kept setting the very
    # variables the start tells it to remove. GPFORUM_LOCAL_CACHE_MAX_ENTRIES
    # defaults to the largest floor, 4096, for the same reason.
    $self->_require_floor(
        $errors,
        {
            actual => $config->local_cache_max_entries,
            field  => 'local_cache_max_entries',
            floor  => $profile->{local_cache_max_entries},
        }
    );
    $self->_require_secret( $errors, $profile, $config );

    return {
        errors  => $errors,
        ok      => keys %{$errors} ? 0 : 1,
        profile => $profile,
    };
}

# The profile's web floor, or what this host can carry when that is less:
# GPFORUM_WEB_PROCESSES=auto sizes to the CPUs, and a floor above them would
# fail every small host the profile otherwise suits. A configuration that
# cannot say what the host carries keeps the profile's floor.
sub _web_floor ( $profile, $config ) {
    my $floor = $profile->{web_processes};
    return $floor if !$config->can('automatic_web_processes');

    return min( $floor, $config->automatic_web_processes );
}

sub _require_floor ( $, $errors, $input ) {
    if ( $input->{actual} < $input->{floor} ) {
        $errors->{ $input->{field} } =
          "$input->{field} is below the operational profile floor";
    }

    return;
}

sub _require_secret ( $, $errors, $profile, $config ) {
    if (  !$profile->{requires_rotated_session_secret}
        || $config->session_secret ne $DEVELOPMENT_SECRET )
    {
        return;
    }

    $errors->{session_secret} = 'rotated session secret is required';

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::Profile - Versioned operational profiles.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = GPForum::Service::Operations::Profile->new->evaluate($config);

=head1 DESCRIPTION

Defines explicit C<development>, C<staging>, C<production-small>, and
C<production-medium> runtime floors plus retention policy. C<production> maps
to C<production-small>. C<test> maps to C<development>. No profile requires
a GlifiStore URL: without one each process keeps its own cache, which a
single host needs no more than; C<requires_glifistore> stays in each profile,
always 0, for the reports that print it. The local cache floor of every
profile is at most C<GPFORUM_LOCAL_CACHE_MAX_ENTRIES>'s default, 4096. The web process floor is the profile's, or
what the host can carry (L<GPForum::Config/automatic_web_processes>) when
that is less. The profiles' C<worker_processes> and C<realtime_processes>
are reported, not compared: the settings they once held up are retired.

=head1 SUBROUTINES/METHODS

=head2 names

Returns the canonical profile names.

=head2 name_for_environment

Maps a config environment string onto a profile name.

=head2 get

Returns a shallow copy of one named profile.

=head2 evaluate

Compares a config object against the profile for its environment.

=head1 DIAGNOSTICS

Returns C<ok> plus field errors instead of throwing.

=head1 CONFIGURATION AND ENVIRONMENT

Reads the web process count, cache size and session secret from
L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<List::Util> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Profiles are floors, not exact sizing. Operators may run more processes than
the selected profile.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
