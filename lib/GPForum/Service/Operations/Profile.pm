# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::Profile;

use Const::Fast;
use List::Util qw(min);
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# Version 2: three environments, sized from the host (ADR 0125). A profile is
# what an environment requires -- a rotated session secret, restore evidence
# -- and the least a node may run at, never its size: web processes and the
# cache come from the host's CPUs and memory (GPForum::Config's automatic
# sizes), and the floors give way to what a small host carries.
const my $PROFILE_VERSION    => 2;
const my $DEVELOPMENT_SECRET => 'gpforum-development-secret-change-me';

# production-small and production-medium are old names of production, read
# as it until GPForum::Config stops reading them; a configuration built with
# new may still carry one.
const my %ENV_TO_PROFILE => (
    development         => 'development',
    test                => 'development',
    staging             => 'staging',
    production          => 'production',
    'production-small'  => 'production',
    'production-medium' => 'production',
);
const my %PROFILES => (
    development => {
        local_cache_max_entries         => 256,
        name                            => 'development',
        requires_glifistore             => 0,
        requires_rotated_session_secret => 0,
        restore_evidence_required       => 0,
        version                         => $PROFILE_VERSION,
        web_processes                   => 1,
    },
    staging => {
        local_cache_max_entries         => 512,
        name                            => 'staging',
        requires_glifistore             => 0,
        requires_rotated_session_secret => 1,
        restore_evidence_required       => 1,
        version                         => $PROFILE_VERSION,
        web_processes                   => 2,
    },
    production => {
        local_cache_max_entries         => 2_048,
        name                            => 'production',
        requires_glifistore             => 0,
        requires_rotated_session_secret => 1,
        restore_evidence_required       => 1,
        version                         => $PROFILE_VERSION,
        web_processes                   => 4,
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
            floor  => _floor_on_this_host( $profile, $config, 'web_processes' ),
        }
    );

    $self->_require_floor(
        $errors,
        {
            actual => $config->local_cache_max_entries,
            field  => 'local_cache_max_entries',
            floor  => _floor_on_this_host(
                $profile, $config, 'local_cache_max_entries'
            ),
        }
    );
    $self->_require_secret( $errors, $profile, $config );

    return {
        errors  => $errors,
        ok      => keys %{$errors} ? 0 : 1,
        profile => $profile,
    };
}

# The profile's floor, or what this host is sized for when that is less: the
# web processes and the cache are sized from the CPUs and the memory, and a
# floor above them would fail every small host the profile otherwise suits.
# A configuration that cannot say what the host carries keeps the floor.
sub _floor_on_this_host ( $profile, $config, $field ) {
    my $floor   = $profile->{$field};
    my $builder = "automatic_$field";
    return $floor if !$config->can($builder);

    return min( $floor, $config->$builder );
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

Defines what the C<development>, C<staging> and C<production> environments
require, version 2 (ADR 0125): a rotated session secret where it is
deployed, restore evidence, and the least a node may run at -- web processes
and cache entries a process. C<test> maps to C<development>;
C<production-small> and C<production-medium>, the old size profiles, map to
C<production>. A profile no longer sizes a node: the web processes and the
cache are sized from the host's CPUs and memory
(L<GPForum::Config/automatic_web_processes>,
L<GPForum::Config/automatic_local_cache_max_entries>), and each floor is the
profile's or what the host is sized for, when that is less. Retention is a
setting of its own, C<GPFORUM_EVENT_RETENTION_DAYS>. No profile requires a
GlifiStore URL; C<requires_glifistore> stays in each, always 0, for the
reports that print it.

=head1 SUBROUTINES/METHODS

=head2 names

Returns the profile names: C<development>, C<production> and C<staging>.

=head2 name_for_environment

Maps a config environment string onto a profile name.

=head2 get

Returns a shallow copy of one named profile.

=head2 evaluate

Compares a config object against the profile for its environment.

=head1 DIAGNOSTICS

Returns C<ok> plus field errors instead of throwing.

=head1 CONFIGURATION AND ENVIRONMENT

Reads the web process count, the cache size, what the host is sized for and
the session secret from L<GPForum::Config>.

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
